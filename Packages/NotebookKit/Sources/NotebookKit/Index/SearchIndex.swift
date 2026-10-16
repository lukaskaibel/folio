#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PDFKit
import Synchronization

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
        /// Its address and its folder's, as keys.
        var path: String
        var folder: String
    }

    public struct TextHit {
        public var entry: Entry
        public var snippet: String
        /// Where the match is in `snippet`.
        public var match: Range<String.Index>?
        /// For a PDF, the page with the match.
        public var page: Int?
    }

    /// Every file, by its address. Only the main thread changes it, and only by the few files that changed: everything
    /// that takes time (reading folders, the text of notes and PDFs) happens in the background first.
    @ObservationIgnored private var byPath: [String: Entry] = [:]
    /// The addresses of the files in each folder, so a folder read again is merged in without going through the rest.
    @ObservationIgnored private var byFolder: [String: Set<String>] = [:]
    /// Counts changes, for what shows the index to update.
    private(set) var version = 0
    public private(set) var isBuilding = false
    /// Called when the index has been built: links in a note opened before resolve now.
    @ObservationIgnored var onBuilt: (() -> Void)?
    /// Folders hidden from the sidebar: what is in them stays out of search, `[[` and Move To, but links still find it.
    @ObservationIgnored var hiddenPaths: [String] = []
    @ObservationIgnored private var generation = 0
    /// Folders that changed while the index was being built, read again once it is.
    @ObservationIgnored private var changedWhileBuilding = Set<URL>()
    @ObservationIgnored private var locations: [Location] = []
    /// The newest reading of each folder, so an older one finishing later doesn't undo it.
    @ObservationIgnored private var newestRefresh: [String: Int] = [:]
    @ObservationIgnored private var refreshes = 0

    public var count: Int {
        _ = version
        return byPath.count
    }

    /// Every file, in no particular order.
    public var entries: [Entry] {
        _ = version
        return Array(byPath.values)
    }

    nonisolated static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    // MARK: - Building

    func rebuild(_ locations: [Location]) {
        generation += 1
        let generation = generation
        self.locations = locations
        isBuilding = true
        changedWhileBuilding = []
        pdfQueue = []
        let roots = locations.flatMap { location in location.folders.map { ($0.url, $0.place, location.id) } }
        Task.detached(priority: .utility) {
            var byPath: [String: Entry] = [:]
            var byFolder: [String: Set<String>] = [:]
            for (root, name, id) in roots {
                for entry in Self.scan(root, locationName: name, locationID: id) {
                    byPath[entry.path] = entry
                    byFolder[entry.folder, default: []].insert(entry.path)
                }
            }
            let pdfs = byPath.values.filter { $0.kind == .pdf && !$0.isInCloud }.map { PDFJob(url: $0.url, path: $0.path, modified: $0.modified) }
            let found = byPath, folders = byFolder
            await MainActor.run {
                guard generation == self.generation else { return }
                // The old index goes away on another thread: freeing the text of thousands of notes takes a while too.
                let old = (self.byPath, self.byFolder)
                DispatchQueue.global(qos: .background).async { withExtendedLifetime(old) {} }
                self.byPath = found
                self.byFolder = folders
                self.version += 1
                self.isBuilding = false
                self.onBuilt?()
                self.readPDFs(pdfs)
                let changed = self.changedWhileBuilding
                self.changedWhileBuilding = []
                if !changed.isEmpty { self.refresh(folders: Array(changed), locations: self.locations) }
            }
        }
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
                     text: text, folded: text.map(fold), foldedName: fold(name), path: url.standardizedFileURL.path, folder: folderPath)
    }

    /// Reads the files in some folders again, after changes there: in the background, then merged in by the files that
    /// changed.
    func refresh(folders: [URL], locations: [Location]) {
        self.locations = locations
        if isBuilding { changedWhileBuilding.formUnion(folders) }
        let paths = Set(folders.map { $0.standardizedFileURL.path })
        let jobs: [(folder: URL, root: URL, place: String, locationID: UUID)] = paths.compactMap { path in
            for location in locations {
                if let base = location.folder(containing: path) { return (URL(fileURLWithPath: path), base.url, base.place, location.id) }
            }
            return nil
        }
        guard !jobs.isEmpty else { return }
        refreshes += 1
        let id = refreshes
        for job in jobs { newestRefresh[job.folder.path] = id }
        let generation = generation
        Task.detached(priority: .utility) {
            var updates: [(folder: String, entries: [Entry])] = []
            for (folder, root, place, locationID) in jobs {
                // A folder that is gone is taken out by reading the one it was in.
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
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
                guard generation == self.generation else { return }
                var pdfs: [PDFJob] = []
                for (folder, found) in scanned where self.newestRefresh[folder] == id {
                    self.newestRefresh[folder] = nil
                    pdfs += self.merge(found, into: folder)
                }
                self.version += 1
                self.readPDFs(pdfs)
            }
        }
    }

    /// Puts what is in a folder now in place of what was, and says which PDFs need their text read.
    private func merge(_ found: [Entry], into folder: String) -> [PDFJob] {
        let paths = Set(found.map(\.path))
        // What was in the folder and is gone, with everything inside a folder that is gone.
        for path in (byFolder[folder] ?? []).subtracting(paths) { remove(path) }
        var pdfs: [PDFJob] = []
        for entry in found {
            var updated = entry
            if entry.kind == .pdf {
                if let old = byPath[entry.path], old.modified == entry.modified, old.text != nil {
                    updated.text = old.text
                    updated.folded = old.folded
                } else if !entry.isInCloud {
                    pdfs.append(PDFJob(url: entry.url, path: entry.path, modified: entry.modified))
                }
            }
            byPath[entry.path] = updated
        }
        byFolder[folder] = paths.isEmpty ? nil : paths
        return pdfs
    }

    private func remove(_ path: String) {
        byPath[path] = nil
        for inside in byFolder.removeValue(forKey: path) ?? [] { remove(inside) }
    }

    // MARK: - PDFs

    private struct PDFJob: Sendable {
        var url: URL
        var path: String
        var modified: Date?
    }

    @ObservationIgnored private var pdfQueue: [PDFJob] = []
    @ObservationIgnored private var pdfTask: Task<Void, Never>?
    nonisolated private static let pdfCache = PDFTextCache()

    /// Reads the text of PDFs in the background, one at a time, so search finds what is in them.
    private func readPDFs(_ jobs: [PDFJob]) {
        pdfQueue += jobs
        guard pdfTask == nil, !pdfQueue.isEmpty else { return }
        pdfTask = Task { [weak self] in
            while let job = self?.nextPDF() {
                let read = await Task.detached(priority: .background) { Self.text(of: job) }.value
                guard let self else { return }
                guard let read, var entry = byPath[job.path], entry.modified == job.modified else { continue }
                entry.text = read.text
                entry.folded = read.folded
                byPath[job.path] = entry
                version += 1
            }
            self?.pdfTask = nil
        }
    }

    private func nextPDF() -> PDFJob? {
        pdfQueue.isEmpty ? nil : pdfQueue.removeFirst()
    }

    nonisolated private static func text(of job: PDFJob) -> (text: String, folded: String)? {
        if let cached = pdfCache.text(for: job.path, modified: job.modified) { return cached }
        guard let document = PDFDocument(url: job.url) else { return nil }
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 300) {
            pages.append(document.page(at: index)?.string ?? "")
        }
        // Pages are separated by form feeds so a hit can say which page it is on.
        let text = pages.joined(separator: "\u{0C}")
        let read = (text, fold(text))
        pdfCache.keep(read, for: job.path, modified: job.modified)
        return read
    }

    // MARK: - Looking things up

    public func entry(for url: URL) -> Entry? {
        _ = version
        return byPath[url.standardizedFileURL.path]
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
        _ = version
        let candidates = byPath.values.filter { entry in
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
        let folder = note?.deletingLastPathComponent().standardizedFileURL.path
        // Nearest the note first: in its folder, then the least deep; then by address, to always pick the same.
        return candidates.min { a, b in
            let aSame = a.folder == folder
            let bSame = b.folder == folder
            if aSame != bSame { return aSame }
            let aDepth = a.url.pathComponents.count, bDepth = b.url.pathComponents.count
            if aDepth != bDepth { return aDepth < bDepth }
            return a.path < b.path
        }?.url
    }

    /// Files whose names match, best first: names starting with the query, then words starting with it, then
    /// containing it, then having its letters in order.
    public func files(matching query: String, limit: Int = 8) -> [Entry] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Entry)] = []
        _ = version
        for entry in byPath.values where entry.kind != .folder {
            guard let score = Self.score(entry.foldedName, q), !isHidden(entry.url) else { continue }
            var total = score
            if entry.kind == .note { total += 5 }
            scored.append((total, entry))
        }
        return scored.sorted { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1.modified != b.1.modified { return (a.1.modified ?? .distantPast) > (b.1.modified ?? .distantPast) }
            return a.1.path < b.1.path
        }.prefix(limit).map(\.1)
    }

    public func folders(matching query: String, limit: Int = 12) -> [Entry] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespaces))
        _ = version
        return byPath.values.filter { $0.kind == .folder && (q.isEmpty || Self.score($0.foldedName, q) != nil) && !isHidden($0.url) }
            .map { (score: Self.score($0.foldedName, q) ?? 0, entry: $0) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.entry.path < $1.entry.path }
            .prefix(limit).map(\.entry)
    }

    /// In a hidden folder, or one itself.
    func isHidden(_ url: URL) -> Bool {
        guard !hiddenPaths.isEmpty else { return false }
        let path = HiddenFolders.withoutPrivate(url.path)
        return hiddenPaths.contains { folder in
            let folder = HiddenFolders.withoutPrivate(folder)
            return path == folder || path.hasPrefix(folder + "/")
        }
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
        _ = version
        for entry in byPath.values.sorted(by: { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }) {
            guard let folded = entry.folded, folded.contains(q), let text = entry.text, !isHidden(entry.url) else { continue }
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
            _ = version
            candidates = byPath.values.filter { $0.kind == .note && $0.url != note && !isHidden($0.url) }.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }.prefix(6).map { $0 }
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

/// The text of PDFs read before, kept for as long as the app runs, for any thread.
private final class PDFTextCache: Sendable {
    private let texts = Mutex<[String: (modified: Date?, text: String, folded: String)]>([:])

    func text(for path: String, modified: Date?) -> (text: String, folded: String)? {
        texts.withLock { texts in
            guard let cached = texts[path], cached.modified == modified else { return nil }
            return (cached.text, cached.folded)
        }
    }

    func keep(_ read: (text: String, folded: String), for path: String, modified: Date?) {
        texts.withLock { $0[path] = (modified, read.text, read.folded) }
    }
}
