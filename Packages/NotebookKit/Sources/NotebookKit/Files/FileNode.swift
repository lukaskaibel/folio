#if os(macOS)
import AppKit
#else
import UIKit
#endif
import UniformTypeIdentifiers

/// What a file is, for its icon and for what opening it does.
public enum FileKind: Equatable, Sendable {
    case folder, note, pdf, image, video, audio, other

    init(url: URL, isDirectory: Bool) {
        if isDirectory { self = .folder; return }
        switch url.pathExtension.lowercased() {
        case "md", "markdown": self = .note
        case "pdf": self = .pdf
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "dng": self = .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": self = .video
        case "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac": self = .audio
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: "folder"
        case .note: "doc.text"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .other: "doc"
        }
    }

    var tint: NSColor {
        switch self {
        case .pdf: Theme.pdf
        case .image: Theme.image
        case .video: Theme.video
        default: Theme.textTertiary
        }
    }
}

/// A file or folder in the sidebar's tree. Folders read their contents only when opened.
@MainActor
public final class FileNode: NSObject {
    public let url: URL
    public private(set) var name: String
    public let kind: FileKind
    /// In iCloud but not on this Mac yet.
    public private(set) var isInCloud: Bool
    public private(set) var modified: Date?
    weak var parent: FileNode?
    private(set) var children: [FileNode]?
    /// A folder from somewhere else shown in a location (iCloud Drive's Desktop), which can't be renamed or moved.
    public let isLinked: Bool
    /// For a location's top: the folders from elsewhere it shows next to its own files.
    var linked: [LinkedFolder] = []

    init(url: URL, kind: FileKind, isInCloud: Bool = false, modified: Date? = nil, parent: FileNode?, linkedAs name: String? = nil) {
        self.url = url
        self.kind = kind
        self.isInCloud = isInCloud
        self.modified = modified
        self.parent = parent
        self.isLinked = name != nil
        self.name = name ?? (kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent)
    }

    public var isFolder: Bool { kind == .folder }

    /// What the sidebar sorts by: the file's name with its extension, a linked folder's own name.
    var sortName: String { isLinked ? name : url.lastPathComponent }

    /// The folder's contents, read from disk now if they haven't been yet. Only for what you just did yourself (a note
    /// you made, a folder you renamed): everything else reads folders off the main thread, with `apply`.
    func loadedChildren() -> [FileNode] {
        if let children { return children }
        apply(Self.list(url, linked: linked))
        return children ?? []
    }

    var hasLoadedChildren: Bool { children != nil }

    /// The folder's contents as the sidebar and the lists show them: only notes and folders if you chose so, and
    /// folders on top or sorted in with the files. Nothing until the folder has been read.
    func visibleChildren() -> [FileNode] {
        let settings = NotebookSettings.shared
        var children = children ?? []
        if settings.showsOnlyNotes { children = children.filter { $0.isFolder || $0.kind == .note } }
        if !settings.foldersFirst {
            children.sort { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        }
        return children
    }

    /// Reads the folder again, keeping the nodes of files that are still there (so open folders stay open).
    @discardableResult
    func reload() -> Bool {
        guard isFolder, children != nil else { return false }
        return apply(Self.list(url, linked: linked))
    }

    /// Takes in what reading the folder found, keeping the nodes of files that are still there. Says whether anything
    /// changed, which a folder read for the first time always has.
    @discardableResult
    func apply(_ listing: [Listing]) -> Bool {
        guard let old = children else {
            children = listing.map { FileNode($0, parent: self) }
            return true
        }
        var byPath: [String: FileNode] = [:]
        for node in old { byPath[node.url.path] = node }
        var changed = listing.count != old.count
        let merged = listing.map { item -> FileNode in
            let name = item.linkedName ?? Self.name(of: item.url, kind: item.kind)
            if let existing = byPath[item.url.path], existing.kind == item.kind, existing.name == name {
                if existing.isInCloud != item.isInCloud || existing.modified != item.modified { changed = true }
                existing.isInCloud = item.isInCloud
                existing.modified = item.modified
                return existing
            }
            changed = true
            return FileNode(item, parent: self)
        }
        if !changed { changed = zip(merged, old).contains { $0 !== $1 } }
        children = merged
        return changed
    }

    private convenience init(_ item: Listing, parent: FileNode) {
        self.init(url: item.url, kind: item.kind, isInCloud: item.isInCloud, modified: item.modified, parent: parent, linkedAs: item.linkedName)
    }

    private static func name(of url: URL, kind: FileKind) -> String {
        kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    func child(named name: String) -> FileNode? {
        loadedChildren().first { !$0.isLinked && $0.url.lastPathComponent == name }
    }

    // MARK: - Reading folders

    /// One file as reading its folder found it: what a node is made from, on the main thread, afterwards.
    struct Listing: Sendable, Equatable {
        var url: URL
        var kind: FileKind
        var isInCloud = false
        var modified: Date?
        /// For a folder from elsewhere shown in a location: its name there.
        var linkedName: String?
    }

    nonisolated static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .ubiquitousItemDownloadingStatusKey, .contentModificationDateKey]

    /// Reads a folder: its files and folders in the sidebar's order, with `linked` among them. This can take a while
    /// (iCloud Drive may have to ask the server first), so apart from what you just did yourself it runs off the main
    /// thread.
    nonisolated static func list(_ folder: URL, linked: [LinkedFolder] = []) -> [Listing] {
        #if DEBUG
        // A slow disk or a slow iCloud, for trying out that nothing waits for it. Reads on the main thread (what you
        // just did yourself) aren't slowed down but logged, to find any that shouldn't be there.
        let delay = UserDefaults.standard.double(forKey: "NotebookSlowFolders")
        if delay > 0 {
            if Thread.isMainThread { NSLog("Notebook: read %@ on the main thread", folder.path) } else { Thread.sleep(forTimeInterval: delay) }
        }
        #endif
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        var items: [(listing: Listing, sortName: String)] = []
        for item in contents {
            var url = item
            var name = item.lastPathComponent
            var inCloud = false
            // Older iCloud Drive placeholders: ".Name.pdf.icloud".
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(7))
                url = folder.appendingPathComponent(name)
                inCloud = true
            } else if name.hasPrefix(".") {
                continue
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isHidden == true, !inCloud { continue }
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if let status = values?.ubiquitousItemDownloadingStatus, status == .notDownloaded { inCloud = true }
            items.append((Listing(url: url, kind: FileKind(url: url, isDirectory: isDirectory), isInCloud: inCloud, modified: values?.contentModificationDate),
                          url.lastPathComponent))
        }
        for folder in linked {
            items.append((Listing(url: folder.url, kind: .folder, linkedName: folder.name), folder.name))
        }
        items.sort { a, b in
            if (a.listing.kind == .folder) != (b.listing.kind == .folder) { return a.listing.kind == .folder }
            return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
        }
        return items.map(\.listing)
    }
}
