import AppKit
import PDFKit

/// Every file in the locations, with the text of every note (and of PDFs), for search, `[[` and resolving links. Built in
/// the background when the app starts and kept up to date as files change.
@MainActor
@Observable
public final class SearchIndex {
    public struct Entry: Sendable {
        public var url: URL
        /// The name shown: a note without ".md".
        public var name: String
        public var kind: FileKind
        /// Where it is, as "Location › Folder › Folder".
        public var place: String
        public var locationID: UUID
        public var modified: Date?
        public var isInCloud: Bool
        /// The text, for notes and PDFs; nil for other files.
        public var text: String?
        var folded: String?
        var foldedName: String
    }

    public struct TextHit {
        public var entry: Entry
        public var snippet: String
        /// Where the match is in `snippet`.
        public var match: Range<String.Index>?
        /// For a PDF, the page with the match.
        public var page: Int?
    }

    public private(set) var entries: [Entry] = []
    public private(set) var isBuilding = false
    private var byPath: [String: Int] = [:]
    private var generation = 0

    nonisolated static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Building

    func rebuild(_ locations: [Location]) {
        generation += 1
        let generation = generation
        isBuilding = true
        let roots = locations.flatMap { location in location.folders.map { ($0.url, $0.place, location.id) } }
        Task.detached(priority: .utility) {
            var result: [Entry] = []
            for (root, name, id) in roots {
                result.append(contentsOf: Self.scan(root, locationName: name, locationID: id))
            }
            let found = result
            await MainActor.run {
                guard generation == self.generation else { return }
                self.entries = found
                self.reindex()
                self.isBuilding = false
                self.indexPDFs()
            }
        }
    }

    private func reindex() {
        byPath = [:]
        for (index, entry) in entries.enumerated() { byPath[entry.url.standardizedFileURL.path] = index }
    }

    nonisolated static func scan(_ root: URL, locationName: String, locationID: UUID) -> [Entry] {
        var result: [Entry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        while let found = enumerator.nextObject() as? URL {
            let url = found.standardizedFileURL
            var name = url.lastPathComponent
            var fileURL = url
            var inCloud = false
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                name = String(name.dropFirst().dropLast(7))
                fileURL = url.deletingLastPathComponent().appendingPathComponent(name)
                inCloud = true
            } else if name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            if ["node_modules", "DerivedData", ".build", "Pods"].contains(name) { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            // Hidden as in the sidebar, like iCloud Drive's links to Desktop and Documents (indexed as folders of their own).
            if values?.isHidden == true, !inCloud {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if values?.ubiquitousItemDownloadingStatus == .notDownloaded { inCloud = true }
            if let entry = makeEntry(fileURL, root: root, locationName: locationName, locationID: locationID, isDirectory: isDirectory,
                                     modified: values?.contentModificationDate, inCloud: inCloud, size: values?.fileSize) {
                result.append(entry)
            }
        }
        return result
    }

    nonisolated static func makeEntry(_ url: URL, root: URL, locationName: String, locationID: UUID, isDirectory: Bool, modified: Date?, inCloud: Bool, size: Int?) -> Entry? {
        let kind = FileKind(url: url, isDirectory: isDirectory)
        let name = kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        let rootPath = root.standardizedFileURL.path
        let folderPath = url.deletingLastPathComponent().standardizedFileURL.path
        let relative = folderPath.hasPrefix(rootPath) ? folderPath.dropFirst(rootPath.count).split(separator: "/").map(String.init) : []
        let place = ([locationName] + relative).joined(separator: " › ")
        var text: String?
        if kind == .note {
            if inCloud {
                // Notes are kept on every device, so search and links work offline.
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            } else if (size ?? 0) < 4_000_000, let data = try? Data(contentsOf: url) {
                text = String(data: data, encoding: .utf8)
            }
        }
        return Entry(url: url, name: name, kind: kind, place: place, locationID: locationID, modified: modified, isInCloud: inCloud,
                     text: text, folded: text.map(fold), foldedName: fold(name))
    }

    /// Reads the files in some folders again, after changes there.
    func refresh(folders: [URL], locations: [Location]) {
        let paths = Set(folders.map { $0.standardizedFileURL.path })
        let jobs: [(folder: URL, root: URL, place: String, locationID: UUID)] = paths.compactMap { path in
            for location in locations {
                if let base = location.folder(containing: path) { return (URL(fileURLWithPath: path), base.url, base.place, location.id) }
            }
            return nil
        }
        guard !jobs.isEmpty else { return }
        Task.detached(priority: .utility) {
            var updates: [(String, [Entry])] = []
            for (folder, root, place, locationID) in jobs {
                var found: [Entry] = []
                let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey]
                let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
                for url in contents where !url.lastPathComponent.hasPrefix(".") {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isHidden == true { continue }
                    let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
                    if let entry = Self.makeEntry(url, root: root, locationName: place, locationID: locationID, isDirectory: isDirectory,
                                                  modified: values?.contentModificationDate, inCloud: values?.ubiquitousItemDownloadingStatus == .notDownloaded, size: values?.fileSize) {
                        found.append(entry)
                    }
                }
                updates.append((folder.standardizedFileURL.path, found))
            }
            let scanned = updates
            await MainActor.run {
                for (folder, found) in scanned {
                    let foundPaths = Set(found.map { $0.url.standardizedFileURL.path })
                    // What was in the folder and is gone, with everything inside a folder that is gone.
                    let removed = self.entries.filter {
                        $0.url.deletingLastPathComponent().standardizedFileURL.path == folder && !foundPaths.contains($0.url.standardizedFileURL.path)
                    }.map { $0.url.standardizedFileURL.path }
                    if !removed.isEmpty {
                        let gone = Set(removed)
                        self.entries.removeAll { entry in
                            let path = entry.url.standardizedFileURL.path
                            return gone.contains(path) || gone.contains { path.hasPrefix($0 + "/") }
                        }
                    }
                    self.reindex()
                    for entry in found {
                        let path = entry.url.standardizedFileURL.path
                        if let index = self.byPath[path] {
                            var updated = entry
                            if entry.kind == .pdf, self.entries[index].modified == entry.modified {
                                updated.text = self.entries[index].text
                                updated.folded = self.entries[index].folded
                            }
                            self.entries[index] = updated
                        } else {
                            self.entries.append(entry)
                            self.byPath[path] = self.entries.count - 1
                        }
                    }
                }
                self.reindex()
                self.indexPDFs()
            }
        }
    }

    // MARK: - PDFs

    private var pdfTask: Task<Void, Never>?
    private static var pdfCache: [String: (Date?, String)] = [:]

    /// Reads the text of PDFs in the background, a few at a time, so search finds what is in them.
    private func indexPDFs() {
        pdfTask?.cancel()
        let pending = entries.filter { $0.kind == .pdf && $0.text == nil && !$0.isInCloud }.map { ($0.url, $0.modified) }
        guard !pending.isEmpty else { return }
        pdfTask = Task { [weak self] in
            for (url, modified) in pending {
                if Task.isCancelled { return }
                let key = url.path
                var text: String?
                if let cached = Self.pdfCache[key], cached.0 == modified {
                    text = cached.1
                } else {
                    text = await Task.detached(priority: .background) { () -> String? in
                        guard let document = PDFDocument(url: url) else { return nil }
                        var pages: [String] = []
                        for index in 0..<min(document.pageCount, 300) {
                            pages.append(document.page(at: index)?.string ?? "")
                        }
                        // Pages are separated by form feeds so a hit can say which page it is on.
                        return pages.joined(separator: "\u{0C}")
                    }.value
                    if let text { Self.pdfCache[key] = (modified, text) }
                }
                guard let self, let text, let index = self.byPath[url.standardizedFileURL.path] else { continue }
                self.entries[index].text = text
                self.entries[index].folded = Self.fold(text)
            }
        }
    }

    // MARK: - Looking things up

    public func entry(for url: URL) -> Entry? {
        byPath[url.standardizedFileURL.path].map { entries[$0] }
    }

    /// The file a `[[link]]` means: by name (".md" for notes left out), nearest to the note it is in first.
    public func resolve(_ target: String, from note: URL?) -> URL? {
        var name = target
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let folded = Self.fold(name)
        let pathPart = folded.contains("/") ? folded : nil
        let baseName = pathPart.map { String($0.split(separator: "/").last ?? "") } ?? folded
        let candidates = entries.filter { entry in
            guard entry.kind != .folder else { return false }
            let full = Self.fold(entry.url.lastPathComponent)
            let matches = entry.kind == .note ? (entry.foldedName == baseName || full == baseName) : full == baseName
            guard matches else { return false }
            if let pathPart {
                let path = Self.fold(entry.url.deletingPathExtension().path)
                return path.hasSuffix("/" + pathPart) || Self.fold(entry.url.path).hasSuffix("/" + pathPart)
            }
            return true
        }
        guard !candidates.isEmpty else { return nil }
        guard let note else { return candidates.first?.url }
        let folder = note.deletingLastPathComponent().standardizedFileURL.path
        return candidates.min { a, b in
            let aSame = a.url.deletingLastPathComponent().standardizedFileURL.path == folder
            let bSame = b.url.deletingLastPathComponent().standardizedFileURL.path == folder
            if aSame != bSame { return aSame }
            return a.url.pathComponents.count < b.url.pathComponents.count
        }?.url
    }

    /// Files whose names match, best first: names starting with the query, then words starting with it, then
    /// containing it, then having its letters in order.
    public func files(matching query: String, limit: Int = 8) -> [Entry] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Entry)] = []
        for entry in entries where entry.kind != .folder {
            guard let score = Self.score(entry.foldedName, q) else { continue }
            var total = score
            if entry.kind == .note { total += 5 }
            scored.append((total, entry))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : ($0.1.modified ?? .distantPast) > ($1.1.modified ?? .distantPast) }.prefix(limit).map(\.1)
    }

    public func folders(matching query: String, limit: Int = 12) -> [Entry] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        return entries.filter { $0.kind == .folder && (q.isEmpty || Self.score($0.foldedName, q) != nil) }
            .sorted { (Self.score($0.foldedName, q) ?? 0) > (Self.score($1.foldedName, q) ?? 0) }
            .prefix(limit).map { $0 }
    }

    nonisolated static func score(_ name: String, _ query: String) -> Int? {
        if name == query { return 100 }
        if name.hasPrefix(query) { return 80 }
        if let range = name.range(of: query) {
            let before = name[..<range.lowerBound].last
            return before == " " || before == "-" || before == "_" ? 60 : 40
        }
        var index = name.startIndex
        for character in query {
            guard let found = name[index...].firstIndex(of: character) else { return nil }
            index = name.index(after: found)
        }
        return 10
    }

    /// Notes and PDFs that contain the query, with the line it is in.
    public func textHits(_ query: String, limit: Int = 8) -> [TextHit] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        var hits: [TextHit] = []
        for entry in entries.sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
            guard let folded = entry.folded, folded.contains(q), let text = entry.text else { continue }
            hits.append(Self.hit(entry, text: text, query: query))
            if hits.count >= limit { break }
        }
        return hits
    }

    private static func hit(_ entry: Entry, text: String, query: String) -> TextHit {
        guard let range = text.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) else {
            return TextHit(entry: entry, snippet: String(text.prefix(120)), match: nil, page: nil)
        }
        var page: Int?
        if entry.kind == .pdf { page = text[..<range.lowerBound].filter { $0 == "\u{0C}" }.count + 1 }
        // The line around the match, at most a few words on each side.
        let lineStart = text[..<range.lowerBound].lastIndex(where: { $0 == "\n" || $0 == "\u{0C}" }).map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(where: { $0 == "\n" || $0 == "\u{0C}" }) ?? text.endIndex
        let start = text.index(range.lowerBound, offsetBy: -48, limitedBy: lineStart) ?? lineStart
        let end = text.index(range.upperBound, offsetBy: 90, limitedBy: lineEnd) ?? lineEnd
        var snippet = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        if start == lineStart { snippet = plainLine(snippet) }
        snippet = snippet.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
        if start > lineStart { snippet = "…" + snippet }
        if end < lineEnd { snippet += "…" }
        let match = snippet.range(of: query.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive])
        return TextHit(entry: entry, snippet: snippet, match: match, page: page)
    }

    /// A line without the Markdown at its start: "> ", "- [ ] ", "## ", "1. ", a callout's "[!tip]".
    private static func plainLine(_ line: String) -> String {
        var result = Substring(line)
        var changed = true
        while changed {
            changed = false
            for prefix in ["> ", ">", "- [ ] ", "- [x] ", "- [X] ", "- ", "* ", "+ "] where result.hasPrefix(prefix) {
                result = result.dropFirst(prefix.count)
                changed = true
            }
            if result.hasPrefix("#") {
                result = result.drop(while: { $0 == "#" }).drop(while: { $0 == " " })
                changed = true
            }
            if result.hasPrefix("[!"), let close = result.firstIndex(of: "]") {
                result = result[result.index(after: close)...].drop(while: { $0 == " " || $0 == "-" || $0 == "+" })
                changed = true
            }
            if let dot = result.firstIndex(of: "."), result[..<dot].allSatisfy(\.isNumber), !result[..<dot].isEmpty, result[result.index(after: dot)...].hasPrefix(" ") {
                result = result[result.index(dot, offsetBy: 2)...]
                changed = true
            }
        }
        return String(result)
    }

    /// What `[[query` could link to.
    func linkSuggestions(_ query: String, from note: URL?) -> [LinkSuggestion] {
        var items: [LinkSuggestion] = []
        let candidates: [Entry]
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            candidates = entries.filter { $0.kind == .note && $0.url != note }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(6).map { $0 }
        } else {
            candidates = files(matching: query, limit: 7).filter { $0.url != note }
        }
        for entry in candidates {
            let insert = entry.kind == .note ? entry.name : entry.url.lastPathComponent
            items.append(LinkSuggestion(kind: entry.kind == .note ? .note : .file, title: entry.kind == .note ? entry.name : entry.url.lastPathComponent,
                                        detail: entry.place.split(separator: "›").suffix(2).joined(separator: "›").trimmingCharacters(in: .whitespaces), insert: insert))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !items.contains(where: { Self.fold($0.title) == Self.fold(trimmed) }) {
            let folder = note.map { $0.deletingLastPathComponent().lastPathComponent } ?? ""
            items.append(LinkSuggestion(kind: .create, title: "New note “\(trimmed)”", detail: folder.isEmpty ? "" : "in \(folder)", insert: trimmed))
        }
        return items
    }
}
