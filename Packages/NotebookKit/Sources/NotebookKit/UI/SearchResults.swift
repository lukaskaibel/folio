import Foundation

/// What a search result opens.
enum SearchResult: Hashable {
    case file(URL)
    case newNote(String)
}

/// One result: a file found by its name or by its text, or a new note with the name searched for.
struct SearchItem: Identifiable, Hashable {
    var result: SearchResult
    var title: String
    /// Where the file is ("iCloud Drive › Travel"), for files found by name and recent ones.
    var place: String?
    var kind: FileKind?
    var isInCloud = false
    /// For text found in a note or PDF: the line it is in, and the words searched for in it.
    var snippet: String?
    var match: Range<String.Index>?

    var id: SearchResult { result }
}

/// The results in their sections: Recent, Files, In Notes and PDFs, and New Note. The Mac's search field shows them
/// in its suggestions menu; iPhone and iPad in a list.
struct SearchSection: Identifiable {
    var title: String?
    var items: [SearchItem]

    var id: String { title ?? "new" }

    @MainActor
    static func sections(for text: String, in workspace: Workspace) -> [SearchSection] {
        let query = text.trimmingCharacters(in: .whitespaces)
        let index = workspace.index
        guard !query.isEmpty else {
            let recent = workspace.recentURLs.prefix(6).map { url in
                SearchItem(result: .file(url), title: displayName(url), place: index.entry(for: url)?.place, kind: FileKind(url: url, isDirectory: false))
            }
            return recent.isEmpty ? [] : [SearchSection(title: "Recent", items: Array(recent))]
        }
        var sections: [SearchSection] = []
        let files = index.files(matching: query, limit: 6)
        if !files.isEmpty {
            sections.append(SearchSection(title: "Files", items: files.map { entry in
                SearchItem(result: .file(entry.url), title: entry.name, place: entry.place, kind: entry.kind, isInCloud: entry.isInCloud)
            }))
        }
        let named = Set(files.map(\.url))
        let hits = index.textHits(query, limit: 6).filter { !named.contains($0.entry.url) }
        if !hits.isEmpty {
            sections.append(SearchSection(title: "In Notes and PDFs", items: hits.map { hit in
                var title = hit.entry.kind == .note ? hit.entry.name : hit.entry.url.lastPathComponent
                if let page = hit.page { title += " – page \(page)" }
                return SearchItem(result: .file(hit.entry.url), title: title, place: hit.entry.place, kind: hit.entry.kind, snippet: hit.snippet, match: hit.match)
            }))
        }
        sections.append(SearchSection(title: nil, items: [SearchItem(result: .newNote(query), title: "New Note “\(query)”")]))
        return sections
    }

    static func displayName(_ url: URL) -> String {
        FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
}
