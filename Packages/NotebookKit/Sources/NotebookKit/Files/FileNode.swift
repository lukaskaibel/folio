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

    /// The folder's contents, read from disk the first time they are asked for.
    func loadedChildren() -> [FileNode] {
        if let children { return children }
        let loaded = Self.read(url, parent: self)
        children = loaded
        return loaded
    }

    var hasLoadedChildren: Bool { children != nil }

    /// The folder's contents as the sidebar and the lists show them: only notes and folders if you chose so, and
    /// folders on top or sorted in with the files.
    func visibleChildren() -> [FileNode] {
        let settings = NotebookSettings.shared
        var children = loadedChildren()
        if settings.showsOnlyNotes { children = children.filter { $0.isFolder || $0.kind == .note } }
        if !settings.foldersFirst {
            children.sort { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }
        }
        return children
    }

    /// Reads the folder again, keeping the nodes of files that are still there (so open folders stay open).
    @discardableResult
    func reload() -> Bool {
        guard isFolder, let old = children else { return false }
        let fresh = Self.read(url, parent: self)
        var byPath: [String: FileNode] = [:]
        for node in old { byPath[node.url.path] = node }
        var changed = fresh.count != old.count
        let merged = fresh.map { node -> FileNode in
            if let existing = byPath[node.url.path], existing.kind == node.kind, existing.name == node.name {
                if existing.isInCloud != node.isInCloud || existing.modified != node.modified { changed = true }
                existing.isInCloud = node.isInCloud
                existing.modified = node.modified
                return existing
            }
            changed = true
            return node
        }
        if !changed { changed = zip(merged, old).contains { $0 !== $1 } }
        children = merged
        return changed
    }

    func child(named name: String) -> FileNode? {
        loadedChildren().first { !$0.isLinked && $0.url.lastPathComponent == name }
    }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .ubiquitousItemDownloadingStatusKey, .contentModificationDateKey]

    static func read(_ folder: URL, parent: FileNode?) -> [FileNode] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        var nodes: [FileNode] = []
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
            nodes.append(FileNode(url: url, kind: FileKind(url: url, isDirectory: isDirectory), isInCloud: inCloud, modified: values?.contentModificationDate, parent: parent))
        }
        for folder in parent?.linked ?? [] {
            nodes.append(FileNode(url: folder.url, kind: .folder, parent: parent, linkedAs: folder.name))
        }
        nodes.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.sortName.localizedStandardCompare(b.sortName) == .orderedAscending
        }
        return nodes
    }
}
