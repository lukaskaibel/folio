import AppKit
import Synchronization

/// An open note: its text, saved shortly after you stop typing, and kept in step with the file when something else
/// (iCloud, another app) changes it.
@MainActor
@Observable
public final class NoteDocument: NSObject, NSFilePresenter {
    public private(set) var url: URL {
        didSet { presentedURL.withLock { $0 = url } }
    }
    /// The address for the file coordinator, which asks for it from other threads.
    @ObservationIgnored private let presentedURL: Mutex<URL>
    public private(set) var text: String
    private(set) var savedText: String
    /// Made with ⌘N and not given a title or text yet; thrown away if left like that.
    var isNew = false
    public private(set) var modified: Date?
    /// The file changed elsewhere while there were unsaved edits here (or iCloud has another version).
    var conflict: Conflict?
    /// Called when the file changed on disk and the new text was taken in.
    @ObservationIgnored var onExternalChange: ((String) -> Void)?
    @ObservationIgnored var onMove: ((URL) -> Void)?
    @ObservationIgnored var onDelete: (() -> Void)?

    @ObservationIgnored private var saveTimer: Timer?
    static let saveDelay: TimeInterval = 0.6

    struct Conflict: Equatable {
        var otherText: String
        var source: String
        var date: Date?
    }

    init(url: URL) {
        self.url = url
        presentedURL = Mutex(url)
        let loaded = Self.read(url) ?? ""
        text = loaded
        savedText = loaded
        modified = Self.modificationDate(url)
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        checkForConflictVersions()
    }

    func close() {
        saveNow()
        saveTimer?.invalidate()
        NSFileCoordinator.removeFilePresenter(self)
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Reading and writing

    static func read(_ url: URL) -> String? {
        var result: String?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            if let data = try? Data(contentsOf: url) {
                result = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            }
        }
        return result
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Takes in what is typed and saves it a moment later.
    func update(text newText: String) {
        guard newText != text else { return }
        text = newText
        if !newText.isEmpty { isNew = false }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard text != savedText, conflict == nil else { return }
        // Never write over a change made elsewhere since the last save: merge it in, or ask.
        if let disk = Self.read(url), disk != savedText {
            if disk == text {
                savedText = disk
                return
            }
            guard let merged = Diff3.merge(base: savedText, mine: text, theirs: disk) else {
                conflict = Conflict(otherText: disk, source: "another device", date: Self.modificationDate(url))
                return
            }
            savedText = disk
            text = merged
            onExternalChange?(merged)
            guard merged != disk else { return }
        }
        let data = Data(text.utf8)
        var error: NSError?
        var written = false
        NSFileCoordinator(filePresenter: self).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            written = (try? data.write(to: url, options: .atomic)) != nil
        }
        if written {
            savedText = text
            modified = Self.modificationDate(url)
        }
    }

    var hasUnsavedChanges: Bool { text != savedText }

    /// Folio moved or renamed the file itself: follow it right away instead of waiting for the coordinator to say so.
    func moved(to newURL: URL) {
        url = newURL.standardizedFileURL
        modified = Self.modificationDate(newURL)
    }

    // MARK: - Conflicts

    private func checkForConflictVersions() {
        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), let other = versions.first,
              let otherText = Self.read(other.url), otherText != text else { return }
        conflict = Conflict(otherText: otherText, source: other.localizedNameOfSavingComputer ?? "another device", date: other.modificationDate)
    }

    enum Resolution { case keepThis, takeOther, keepBoth }

    /// Settles a conflict; returns the text to show.
    func resolve(_ resolution: Resolution) -> String {
        guard let conflict else { return text }
        switch resolution {
        case .keepThis:
            break
        case .takeOther:
            text = conflict.otherText
        case .keepBoth:
            let base = url.deletingPathExtension().lastPathComponent
            let copy = FileOperations.uniqueURL(in: url.deletingLastPathComponent(), name: "\(base) (\(conflict.source))", extension: "md")
            try? Data(conflict.otherText.utf8).write(to: copy, options: .atomic)
        }
        self.conflict = nil
        if let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) {
            for version in versions { version.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        // The choice is made: what is on disk now is the base, and this note's text goes over it.
        savedText = Self.read(url) ?? ""
        saveNow()
        return text
    }

    // MARK: - NSFilePresenter

    nonisolated public var presentedItemURL: URL? {
        presentedURL.withLock { $0 }
    }

    nonisolated public var presentedItemOperationQueue: OperationQueue { .main }

    nonisolated public func presentedItemDidChange() {
        MainActor.assumeIsolated { fileChangedOnDisk() }
    }

    nonisolated public func presentedItemDidMove(to newURL: URL) {
        MainActor.assumeIsolated {
            url = newURL
            onMove?(newURL)
        }
    }

    nonisolated public func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated {
            saveTimer?.invalidate()
            onDelete?()
        }
        completionHandler(nil)
    }

    nonisolated public func presentedItemDidGain(_ version: NSFileVersion) {
        MainActor.assumeIsolated { checkForConflictVersions() }
    }

    nonisolated public func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated { saveNow() }
        completionHandler(nil)
    }

    private func fileChangedOnDisk() {
        guard let disk = Self.read(url), disk != savedText else { return }
        modified = Self.modificationDate(url)
        if text == savedText {
            text = disk
            savedText = disk
            onExternalChange?(disk)
        } else if let merged = Diff3.merge(base: savedText, mine: text, theirs: disk) {
            // Edits here and there touched different lines: keep both.
            savedText = disk
            text = merged
            onExternalChange?(merged)
            if merged != disk { saveNow() }
        } else {
            conflict = Conflict(otherText: disk, source: "another device", date: modified)
        }
        checkForConflictVersions()
    }
}
