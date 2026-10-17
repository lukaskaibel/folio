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
        /// The file's name with its extension, folded: what a link to a file other than a note gives.
        var foldedFileName: String
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
    /// The addresses of the files by their folded names (a note's with and without ".md"), so a link finds its file at
    /// once, without going through every file there is.
    @ObservationIgnored private var byName: [String: Set<String>] = [:]
    /// The addresses of every folder, for Move To.
    @ObservationIgnored private var folderPaths: Set<String> = []
    /// Counts changes, for what shows the index to update.
    private(set) var version = 0
    /// Counts the times folders came or went, which is far less often than files change.
    private(set) var folderVersion = 0
    /// Called when folders came or went.
    @ObservationIgnored var onFoldersChanged: (() -> Void)?
    public private(set) var isBuilding = false
    /// Called when the index has been built: links in a note opened before resolve now.
    @ObservationIgnored var onBuilt: (() -> Void)?
    /// Called when folders have been read again: links to what changed in them resolve now.
    @ObservationIgnored var onRefreshed: (() -> Void)?
    /// Folders hidden from the sidebar: what is in them stays out of search, `[[` and Move To, but links still find it.
    @ObservationIgnored var hiddenPaths: [String] = []
    @ObservationIgnored private var generation = 0
    /// Folders that changed while the index was being built, read again once it is.
    @ObservationIgnored private var changedWhileBuilding = Set<URL>()
    @ObservationIgnored private var locations: [Location] = []
    /// The newest reading of each folder, so an older one finishing later doesn't undo it.
    @ObservationIgnored private var newestRefresh: [String: Int] = [:]
    @ObservationIgnored private var refreshes = 0
    /// A folder went while folders were merged in (one replacing it keeps their number the same).
    @ObservationIgnored private var foldersChanged = false

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
        var folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Made Swift's own, not left as Foundation's string, so search goes through it without copying it each time.
        folded.makeContiguousUTF8()
        return folded
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
            var byName: [String: Set<String>] = [:]
            var folderPaths: Set<String> = []
            for (root, name, id) in roots {
                for entry in Self.scan(root, locationName: name, locationID: id) {
                    byPath[entry.path] = entry
                    byFolder[entry.folder, default: []].insert(entry.path)
                    for key in Self.nameKeys(of: entry) { byName[key, default: []].insert(entry.path) }
                    if entry.kind == .folder { folderPaths.insert(entry.path) }
                }
            }
            let pdfs = byPath.values.filter { $0.kind == .pdf && !$0.isInCloud }.map { PDFJob(url: $0.url, path: $0.path, modified: $0.modified) }
            let found = byPath, folders = byFolder, names = byName, allFolders = folderPaths
            await MainActor.run {
                guard generation == self.generation else { return }
                // The old index goes away on another thread: freeing the text of thousands of notes takes a while too.
                let old = (self.byPath, self.byFolder, self.byName, self.folderPaths)
                DispatchQueue.global(qos: .background).async { withExtendedLifetime(old) {} }
                self.byPath = found
                self.byFolder = folders
                self.byName = names
                self.folderPaths = allFolders
                self.version += 1
                self.folderVersion += 1
                self.isBuilding = false
                self.onBuilt?()
                self.onFoldersChanged?()
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
                     text: text, folded: text.map(fold), foldedName: fold(name), foldedFileName: fold(url.lastPathComponent),
                     path: url.standardizedFileURL.path, folder: folderPath)
    }

    /// The names a link finds a file by: a note's with and without ".md", any other file's in full. None for folders.
    nonisolated private static func nameKeys(of entry: Entry) -> [String] {
        switch entry.kind {
        case .folder: []
        case .note: entry.foldedName == entry.foldedFileName ? [entry.foldedName] : [entry.foldedName, entry.foldedFileName]
        default: [entry.foldedFileName]
        }
    }

    /// Reads the files in some folders again, after changes there: in the background, then merged in by the files that
    /// changed. Folders among them that are `deep` (renamed or moved, under their new address) are read with every
    /// folder in them.
    func refresh(folders: [URL], deep: [URL] = [], locations: [Location]) {
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
        let deep = Set(deep.map { $0.standardizedFileURL.path })
        Task.detached(priority: .utility) {
            var updates: [(folder: String, entries: [Entry])] = []
            var jobs = jobs
            for job in jobs where deep.contains(job.folder.path) {
                jobs += Self.subfolders(of: job.folder).map { ($0, job.root, job.place, job.locationID) }
            }
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
                let folders = self.folderPaths.count
                // Folders found in a deep one were asked for by nobody else, unless since.
                for (folder, found) in scanned where self.newestRefresh[folder] ?? id == id {
                    self.newestRefresh[folder] = nil
                    pdfs += self.merge(found, into: folder)
                }
                self.version += 1
                if self.foldersChanged || self.folderPaths.count != folders {
                    self.foldersChanged = false
                    self.folderVersion += 1
                    self.onFoldersChanged?()
                }
                self.readPDFs(pdfs)
                self.onRefreshed?()
            }
        }
    }

    /// Every folder in a folder, as `scan` goes through them.
    nonisolated private static func subfolders(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        var folders: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true, values?.isPackage != true else { continue }
            if url.lastPathComponent.hasPrefix(".") || values?.isHidden == true || ["node_modules", "DerivedData", ".build", "Pods"].contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            folders.append(url.standardizedFileURL)
        }
        return folders
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
            let old = byPath.updateValue(updated, forKey: entry.path)
            if old?.kind != entry.kind {
                if let old { forget(old) }
                for key in Self.nameKeys(of: entry) { byName[key, default: []].insert(entry.path) }
                if entry.kind == .folder { folderPaths.insert(entry.path) }
            }
        }
        byFolder[folder] = paths.isEmpty ? nil : paths
        return pdfs
    }

    private func remove(_ path: String) {
        if let entry = byPath.removeValue(forKey: path) { forget(entry) }
        for inside in byFolder.removeValue(forKey: path) ?? [] { remove(inside) }
    }

    /// Takes a file that is gone, or is something else now, out of the lookups by name and of the folders.
    private func forget(_ entry: Entry) {
        for key in Self.nameKeys(of: entry) {
            byName[key]?.remove(entry.path)
            if byName[key]?.isEmpty == true { byName[key] = nil }
        }
        if entry.kind == .folder, folderPaths.remove(entry.path) != nil { foldersChanged = true }
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
                let hadText = entry.folded != nil
                entry.text = read.text
                entry.folded = read.folded
                byPath[job.path] = entry
                version += 1
                // What search goes through stays as it was but for this PDF, rather than being made again for each one.
                if madeLists?.version == version - 1 {
                    madeLists?.version = version
                    if !hadText { madeLists?.addText(job.path, modified: entry.modified ?? .distantPast) }
                }
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

    /// What search goes through for every letter typed, made again only when files changed: every file's name, and
    /// the notes and PDFs with text, newest first. Going through the index itself would copy every entry, text and
    /// all, and sorting it by date every time took most of a second for a whole iCloud Drive.
    private struct Lists {
        struct File {
            var foldedName: String
            var isNote: Bool
            var modified: Date
            var path: String
        }

        var version: Int
        var files: [File] = []
        var newestWithText: [(modified: Date, path: String)] = []

        mutating func addText(_ path: String, modified: Date) {
            let index = newestWithText.firstIndex { $0.modified < modified } ?? newestWithText.count
            newestWithText.insert((modified, path), at: index)
        }
    }

    @ObservationIgnored private var madeLists: Lists?

    private var lists: Lists {
        if let madeLists, madeLists.version == version { return madeLists }
        var lists = Lists(version: version)
        lists.files.reserveCapacity(byPath.count)
        for entry in byPath.values {
            let modified = entry.modified ?? .distantPast
            if entry.kind != .folder { lists.files.append(Lists.File(foldedName: entry.foldedName, isNote: entry.kind == .note, modified: modified, path: entry.path)) }
            if entry.folded != nil { lists.newestWithText.append((modified, entry.path)) }
        }
        lists.newestWithText.sort { $0.modified > $1.modified }
        madeLists = lists
        return lists
    }

    /// The first few of many, in order, without sorting them all.
    private struct Best<Item> {
        let limit: Int
        let isBefore: (Item, Item) -> Bool
        private(set) var items: [Item] = []

        init(_ limit: Int, by isBefore: @escaping (Item, Item) -> Bool) {
            self.limit = limit
            self.isBefore = isBefore
        }

        /// Whether `item` would be among them.
        func takes(_ item: Item) -> Bool {
            items.count < limit || items.last.map { isBefore(item, $0) } == true
        }

        mutating func add(_ item: Item) {
            let index = items.firstIndex { isBefore(item, $0) } ?? items.count
            items.insert(item, at: index)
            if items.count > limit { items.removeLast() }
        }
    }

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
        let candidates = (byName[baseName] ?? []).compactMap { byPath[$0] }.filter { entry in
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
        var best = Best<(score: Int, file: Lists.File)>(limit) { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.file.modified != b.file.modified { return a.file.modified > b.file.modified }
            return a.file.path < b.file.path
        }
        for file in lists.files {
            guard let score = Self.score(file.foldedName, q) else { continue }
            let candidate = (score: score + (file.isNote ? 5 : 0), file: file)
            if best.takes(candidate), !Self.isHidden(file.path, in: hiddenPaths) { best.add(candidate) }
        }
        return best.items.compactMap { byPath[$0.file.path] }
    }

    /// Every folder, in no particular order, hidden ones too: for Move To.
    func allFolders() -> [(url: URL, name: String, path: String)] {
        _ = folderVersion
        return folderPaths.compactMap { path in byPath[path].map { ($0.url, $0.name, path) } }
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
        Self.isHidden(url.path, in: hiddenPaths)
    }

    nonisolated static func isHidden(_ path: String, in hiddenPaths: [String]) -> Bool {
        guard !hiddenPaths.isEmpty else { return false }
        let path = HiddenFolders.withoutPrivate(path)
        return hiddenPaths.contains { folder in
            let folder = HiddenFolders.withoutPrivate(folder)
            return path == folder || path.hasPrefix(folder + "/")
        }
    }

    nonisolated static func score(_ name: String, _ query: String) -> Int? {
        if name == query { return 100 }
        if query.isEmpty { return 80 }
        if let offset = offset(of: query, in: name) {
            guard offset > 0 else { return 80 }
            let before = name.utf8[name.utf8.index(name.utf8.startIndex, offsetBy: offset - 1)]
            return before == UInt8(ascii: " ") || before == UInt8(ascii: "-") || before == UInt8(ascii: "_") ? 60 : 40
        }
        var letters = name.unicodeScalars.makeIterator()
        for wanted in query.unicodeScalars {
            while true {
                guard let letter = letters.next() else { return nil }
                if letter == wanted { break }
            }
        }
        return 10
    }

    /// Where `query` is in `text`, in bytes. Both are folded alike, so their bytes match where their letters do; this
    /// is far faster than String's own search, and it runs on every file for every letter typed.
    nonisolated static func offset(of query: String, in text: String) -> Int? {
        var text = text, query = query
        return text.withUTF8 { text in
            query.withUTF8 { query -> Int? in
                guard !query.isEmpty, query.count <= text.count, let start = text.baseAddress,
                      let found = memmem(start, text.count, query.baseAddress, query.count) else { return nil }
                return UnsafeRawPointer(found) - UnsafeRawPointer(start)
            }
        }
    }

    /// Notes and PDFs that contain the query, with the line it is in.
    public func textHits(_ query: String, limit: Int = 8) -> [TextHit] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        var hits: [TextHit] = []
        for (_, path) in lists.newestWithText {
            guard let entry = byPath[path], let folded = entry.folded, Self.offset(of: q, in: folded) != nil, let text = entry.text, !isHidden(entry.url) else { continue }
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
            let current = note?.standardizedFileURL.path
            var newest = Best<Lists.File>(6) { $0.modified > $1.modified }
            for file in lists.files where file.isNote && file.path != current && newest.takes(file) && !Self.isHidden(file.path, in: hiddenPaths) {
                newest.add(file)
            }
            candidates = newest.items.compactMap { byPath[$0.path] }
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
