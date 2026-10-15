import AppKit
import SwiftUI

/// One row in ⌘K.
struct PaletteItem: Identifiable {
    var id: String
    var symbol: String
    var tint: Color = .theme(Theme.textTertiary)
    var title: AttributedString
    var snippet: AttributedString?
    var detail: String = ""
    var shortcut: String?
    var run: () -> Void
}

struct PaletteSection: Identifiable {
    var id: String { title }
    var title: String
    var items: [PaletteItem]
}

/// ⌘K: one field that finds files by name, text in notes and PDFs, and commands. With "Move to…" it lists folders.
struct CommandPalette: View {
    let workspace: Workspace
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    var body: some View {
        let sections = makeSections()
        let items = sections.flatMap(\.items)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.theme(Theme.textTertiary))
                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { move(1, items.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                    .onKeyPress(.tab) { move(1, items.count); return .handled }
                    .accessibilityLabel("Search or run a command")
                Keycap("esc")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            Rectangle().fill(Color.theme(Theme.separator)).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty {
                            Text(workspace.index.isBuilding ? "Reading your files…" : "Nothing found")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.theme(Theme.textTertiary))
                                .padding(18)
                        }
                        ForEach(Array(starts(sections).enumerated()), id: \.element.section.id) { _, entry in
                            Text(entry.section.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.theme(Theme.textTertiary))
                                .padding(.horizontal, 18)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(Array(entry.section.items.enumerated()), id: \.element.id) { position, item in
                                let index = entry.start + position
                                row(item, selected: index == selected)
                                    .id(item.id)
                                    .onTapGesture { selected = index; run(items) }
                                    .onHover { if $0 { selected = index } }
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(height: listHeight(sections))
                .onChange(of: selected) { _, value in
                    if let id = items[safe: value]?.id { proxy.scrollTo(id) }
                }
            }
            Rectangle().fill(Color.theme(Theme.separator)).frame(height: 1)
            HStack(spacing: 18) {
                hint(["↑", "↓"], "choose")
                hint(["↵"], "open")
                Spacer()
                if case .search = workspace.paletteMode { hint([">"], "commands only") }
            }
            .padding(.horizontal, 18)
            .frame(height: 36)
        }
        .frame(width: 640)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.theme(Theme.popover)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.theme(Theme.popoverBorder)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 32, y: 16)
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private var placeholder: String {
        if case .move(let url) = workspace.paletteMode { return "Move “\(url.deletingPathExtension().lastPathComponent)” to…" }
        return "Search or run a command…"
    }

    /// As tall as the results, up to a limit.
    private func listHeight(_ sections: [PaletteSection]) -> CGFloat {
        let items = sections.flatMap(\.items)
        guard !items.isEmpty else { return 52 }
        let rows = items.reduce(CGFloat(0)) { $0 + ($1.snippet == nil ? 38 : 52) }
        return min(440, rows + CGFloat(sections.count) * 33 + 8)
    }

    /// Each section with the index its first item has among all items.
    private func starts(_ sections: [PaletteSection]) -> [(section: PaletteSection, start: Int)] {
        var start = 0
        return sections.map { section in
            defer { start += section.items.count }
            return (section, start)
        }
    }

    private func move(_ delta: Int, _ count: Int) {
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    private func run(_ items: [PaletteItem]) {
        guard let item = items[safe: selected] else { return }
        close()
        item.run()
    }

    private func close() {
        workspace.isPaletteOpen = false
        workspace.paletteMode = .search
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(alignment: item.snippet == nil ? .center : .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 14))
                .foregroundStyle(item.tint)
                .frame(width: 18)
                .padding(.top, item.snippet == nil ? 0 : 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14)).lineLimit(1)
                if let snippet = item.snippet {
                    Text(snippet).font(.system(size: 12.5)).foregroundStyle(Color.theme(Theme.textSecondary)).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 12.5)).foregroundStyle(Color.theme(Theme.textTertiary)).lineLimit(1)
            }
            if let shortcut = item.shortcut { Keycap(shortcut) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, item.snippet == nil ? 0 : 7)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.theme(Theme.popoverSelected) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { Keycap($0) }
            Text(label)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.theme(Theme.textTertiary))
    }

    // MARK: - Results

    private func highlighted(_ text: String, _ query: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, let range = result.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].backgroundColor = Color.theme(Theme.searchMark)
        }
        return result
    }

    private func makeSections() -> [PaletteSection] {
        if case .move(let url) = workspace.paletteMode {
            let folders = workspace.index.folders(matching: query, limit: 14).filter { $0.url != url.deletingLastPathComponent() && !$0.url.path.hasPrefix(url.path + "/") && $0.url != url }
            var items = folders.map { entry in
                PaletteItem(id: entry.url.path, symbol: "folder", title: highlighted(entry.name, query), detail: entry.place) { [workspace] in
                    workspace.move(url, into: entry.url)
                }
            }
            for location in workspace.locations where query.isEmpty && url.deletingLastPathComponent() != location.url {
                items.insert(PaletteItem(id: location.path, symbol: location.isICloudDrive ? "icloud" : "externaldrive", title: AttributedString(location.name), detail: "Top level") { [workspace] in
                    workspace.move(url, into: location.url)
                }, at: 0)
            }
            return [PaletteSection(title: "Folders", items: items)]
        }

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            let filter = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            return [PaletteSection(title: "Commands", items: commands(filter))]
        }
        var sections: [PaletteSection] = []
        if trimmed.isEmpty {
            let recent = workspace.recents.prefix(6).compactMap { path -> PaletteItem? in
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                return fileItem(url, name: FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
                                place: workspace.index.entry(for: url)?.place ?? "")
            }
            if !recent.isEmpty { sections.append(PaletteSection(title: "Recent", items: recent)) }
            sections.append(PaletteSection(title: "Commands", items: commands("")))
            return sections
        }
        let files = workspace.index.files(matching: trimmed, limit: 6).map { entry in
            fileItem(entry.url, name: entry.name, place: entry.place, inCloud: entry.isInCloud)
        }
        if !files.isEmpty { sections.append(PaletteSection(title: "Files", items: files)) }
        let fileIDs = Set(files.map(\.id))
        let hits = workspace.index.textHits(trimmed, limit: 6).filter { !fileIDs.contains("text:" + $0.entry.url.path) }.map { hit -> PaletteItem in
            var title = AttributedString(hit.entry.kind == .note ? hit.entry.name : hit.entry.url.lastPathComponent)
            if let page = hit.page {
                var suffix = AttributedString("  ·  page \(page)")
                suffix.foregroundColor = Color.theme(Theme.textTertiary)
                title += suffix
            }
            var snippet = AttributedString(hit.snippet)
            if let match = hit.match, let range = Range(match, in: snippet) {
                snippet[range].backgroundColor = Color.theme(Theme.searchMark)
                snippet[range].foregroundColor = Color.theme(Theme.text)
            }
            return PaletteItem(id: "text:" + hit.entry.url.path, symbol: hit.entry.kind.symbol, tint: Color.theme(hit.entry.kind.tint), title: title, snippet: snippet,
                               detail: hit.entry.place) { [workspace] in workspace.open(hit.entry.url) }
        }
        if !hits.isEmpty { sections.append(PaletteSection(title: "In notes and files", items: hits)) }
        let commandItems = commands(trimmed)
        if !commandItems.isEmpty { sections.append(PaletteSection(title: "Commands", items: commandItems)) }
        return sections
    }

    private func fileItem(_ url: URL, name: String, place: String, inCloud: Bool = false) -> PaletteItem {
        let kind = FileKind(url: url, isDirectory: false)
        return PaletteItem(id: url.path, symbol: inCloud ? "icloud.and.arrow.down" : kind.symbol, tint: Color.theme(kind.tint), title: highlighted(name, query), detail: place) { [workspace] in
            workspace.open(url)
        }
    }

    private func commands(_ filter: String) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !query.hasPrefix(">") {
            items.append(PaletteItem(id: "cmd:new-named", symbol: "square.and.pencil", tint: Color.theme(Theme.accent), title: AttributedString("New note “\(trimmed)”"), shortcut: nil) { [workspace] in
                workspace.newNote(title: trimmed)
            })
        }
        var all: [PaletteItem] = [
            PaletteItem(id: "cmd:new", symbol: "square.and.pencil", title: "New note", shortcut: "⌘N") { [workspace] in workspace.newNote() },
            PaletteItem(id: "cmd:folder", symbol: "folder.badge.plus", title: "New folder", shortcut: "⇧⌘N") { [workspace] in workspace.newFolder() },
        ]
        if let current = workspace.currentURL {
            let name = current.deletingPathExtension().lastPathComponent
            all.append(PaletteItem(id: "cmd:move", symbol: "folder", title: AttributedString("Move “\(name)” to…"), shortcut: "⇧⌘M") { [workspace] in
                DispatchQueue.main.async {
                    workspace.paletteMode = .move(current)
                    workspace.isPaletteOpen = true
                }
            })
            let favorite = workspace.isFavorite(current)
            all.append(PaletteItem(id: "cmd:fav", symbol: favorite ? "star.slash" : "star", title: AttributedString(favorite ? "Remove from favorites" : "Add to favorites")) { [workspace] in
                workspace.toggleFavorite(current)
            })
            all.append(PaletteItem(id: "cmd:finder", symbol: "folder", title: "Show in Finder") { [workspace] in workspace.revealInFinder(current) })
            all.append(PaletteItem(id: "cmd:link", symbol: "link", title: AttributedString("Copy link to “\(name)”")) { [workspace] in workspace.copyLink(current) })
            all.append(PaletteItem(id: "cmd:trash", symbol: "trash", title: AttributedString("Move “\(name)” to the Trash")) { [workspace] in workspace.trash(current) })
        }
        all.append(PaletteItem(id: "cmd:location", symbol: "plus.rectangle.on.folder", title: "Add a location…") { [workspace] in workspace.chooseLocation(iCloud: false) })
        all.append(PaletteItem(id: "cmd:sidebar", symbol: "sidebar.left", title: AttributedString(workspace.isSidebarVisible ? "Hide sidebar" : "Show sidebar"), shortcut: "⌃⌘S") { [workspace] in
            withAnimation(Theme.spring) { workspace.isSidebarVisible.toggle() }
        })
        if workspace.canGoBack { all.append(PaletteItem(id: "cmd:back", symbol: "chevron.left", title: "Go back", shortcut: "⌘[") { [workspace] in workspace.goBack() }) }
        let folded = SearchIndex.fold(trimmed)
        items += all.filter { trimmed.isEmpty || SearchIndex.score(SearchIndex.fold(String($0.title.characters)), folded) != nil }
        return items
    }
}

struct Keycap: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.theme(Theme.textSecondary))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.theme(Theme.keycap)))
    }
}
