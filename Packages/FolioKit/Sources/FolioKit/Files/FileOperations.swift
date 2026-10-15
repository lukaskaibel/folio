import AppKit

/// Creating, renaming, moving and deleting files, coordinated so iCloud and other apps see each change whole.
@MainActor
enum FileOperations {
    /// A name that isn't taken in the folder: "Untitled", "Untitled 2", …
    static func uniqueURL(in folder: URL, name: String, extension ext: String?) -> URL {
        func make(_ base: String) -> URL {
            ext.map { folder.appendingPathComponent(base).appendingPathExtension($0) } ?? folder.appendingPathComponent(base, isDirectory: true)
        }
        var candidate = make(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(name) \(counter)")
            counter += 1
        }
        return candidate
    }

    /// A file name from a title: the characters files can't have become dashes.
    static func fileName(from title: String) -> String {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for character in ["/", ":", "\\"] { name = name.replacingOccurrences(of: character, with: "-") }
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(200))
    }

    @discardableResult
    static func createNote(in folder: URL, title: String = "Untitled", text: String = "") -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(in: folder, name: fileName(from: title).isEmpty ? "Untitled" : fileName(from: title), extension: "md")
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { url in
            written = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
        }
        return written ? url : nil
    }

    @discardableResult
    static func createFolder(in parent: URL, name: String = "New Folder") -> URL? {
        let url = uniqueURL(in: parent, name: name, extension: nil)
        var created = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: nil) { url in
            created = (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil
        }
        return created ? url : nil
    }

    /// Moves a file or folder, coordinated. Returns where it ended up.
    @discardableResult
    static func move(_ url: URL, to destination: URL) -> URL? {
        guard url.standardizedFileURL != destination.standardizedFileURL else { return url }
        var moved = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                moved = true
            } catch {
                moved = false
            }
        }
        return moved ? destination : nil
    }

    /// Renames, keeping the extension of a file. Returns the new address, or nil when the name is taken or invalid.
    static func rename(_ url: URL, to name: String) -> URL? {
        let clean = fileName(from: name)
        guard !clean.isEmpty else { return nil }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var destination = url.deletingLastPathComponent().appendingPathComponent(clean, isDirectory: isDirectory)
        if !isDirectory, !url.pathExtension.isEmpty { destination = destination.appendingPathExtension(url.pathExtension) }
        guard destination.path != url.path else { return url }
        // Only the case changed: the file system calls that the same name.
        if destination.path.lowercased() != url.path.lowercased(), FileManager.default.fileExists(atPath: destination.path) { return nil }
        return move(url, to: destination)
    }

    static func trash(_ url: URL) -> Bool {
        var trashed = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
            trashed = (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
        }
        return trashed
    }

    static func duplicate(_ url: URL) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
        let destination = uniqueURL(in: url.deletingLastPathComponent(), name: "\(base) copy", extension: ext)
        var copied = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], writingItemAt: destination, options: .forReplacing, error: nil) { from, to in
            copied = (try? FileManager.default.copyItem(at: from, to: to)) != nil
        }
        return copied ? destination : nil
    }

    // MARK: - Links

    /// After a note was renamed, points every `[[Old]]` (and `[[Old|…]]`, `[[Old#…]]`, `![[Old]]`) in the notes
    /// under `root` at the new name. Returns how many notes changed.
    @discardableResult
    static func updateLinks(from oldName: String, to newName: String, under root: URL, skipping: URL? = nil) -> Int {
        guard oldName != newName, let expression = try? NSRegularExpression(
            pattern: "(!?\\[\\[)" + NSRegularExpression.escapedPattern(for: oldName) + "(\\.md)?(?=(\\]\\]|\\||#))",
            options: [.caseInsensitive]
        ) else { return 0 }
        var changed = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "md", url.standardizedFileURL != skipping?.standardizedFileURL,
                  let text = NoteDocument.read(url), text.contains("[[") else { continue }
            let range = NSRange(location: 0, length: (text as NSString).length)
            let template = "$1" + NSRegularExpression.escapedTemplate(for: newName)
            let updated = expression.stringByReplacingMatches(in: text, range: range, withTemplate: template)
            guard updated != text else { continue }
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { url in
                try? Data(updated.utf8).write(to: url, options: .atomic)
            }
            changed += 1
        }
        return changed
    }

    /// Pictures and files in a folder's `.assets` that no note in the folder uses any more, among `candidates`,
    /// go to the Trash.
    static func cleanUpAssets(in folder: URL, candidates: Set<String>) {
        guard !candidates.isEmpty else { return }
        let notes = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var used = Set<String>()
        for note in notes where note.pathExtension.lowercased() == "md" {
            guard let text = NoteDocument.read(note) else { continue }
            used.formUnion(assetNames(in: text))
        }
        for name in candidates.subtracting(used) {
            let url = folder.appendingPathComponent(".assets").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { _ = trash(url) }
        }
    }

    /// The `.assets` files a note's Markdown points at, by file name.
    static func assetNames(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: "\\.assets/([^)\\s\\]|]+)") else { return [] }
        var names = Set<String>()
        for match in expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
            let raw = (text as NSString).substring(with: match.range(at: 1))
            names.insert(raw.removingPercentEncoding ?? raw)
        }
        return names
    }
}
