#if os(iOS)
import SwiftUI
import UIKit

/// A file or folder in a list, as the Files app shows one: its symbol in its kind's colour, the name, and a cloud for
/// a file that is still only in iCloud. Notes say when they were changed and how they start, as in Notes.
struct FileRow: View {
    let workspace: Workspace
    let url: URL
    let name: String
    let kind: FileKind
    var isInCloud = false
    /// Instead of the kind's symbol: a star for a favourite folder, a cloud for iCloud Drive.
    var symbol: String?
    /// Shows the date and the start of a note, or the date and size of a file, under the name.
    var showsDetail = false

    var body: some View {
        let dimmed = FolioSettings.shared.dimsOtherFiles && kind != .folder && kind != .note
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(dimmed || isInCloud ? .secondary : .primary)
                if showsDetail, let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: symbol ?? kind.symbol)
                .foregroundStyle(tint)
                .opacity(dimmed ? 0.5 : 1)
        }
        .badge(isInCloud ? Text(Image(systemName: "icloud.and.arrow.down")) : nil)
        .accessibilityLabel(isInCloud ? "\(name), in iCloud" : name)
    }

    private var tint: Color {
        switch kind {
        case .folder: .accentColor
        case .note, .other, .audio: .secondary
        default: Color.theme(kind.tint)
        }
    }

    /// "Yesterday  Get an ICOCA card at the airport…" for a note; "12 Oct 2026 · 84 KB" for any other file.
    private var detail: String? {
        guard kind != .folder else { return nil }
        let entry = workspace.index.entry(for: url)
        let date = entry?.modified.map(Self.shortDate)
        if kind == .note {
            let start = entry?.text.map(Self.firstLine) ?? ""
            return [date, start.isEmpty ? "No additional text" : start].compactMap { $0 }.joined(separator: "  ")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [date, size].compactMap { $0 }.joined(separator: " · ")
    }

    /// As Notes dates a note: the time today, "Yesterday", the weekday this week, the date before that.
    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// The first line of a note with words in it, as you read it: without its Markdown.
    @MainActor
    static func firstLine(_ text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(12) {
            var plain = line.trimmingCharacters(in: .whitespaces)
            if plain.hasPrefix("---") || plain.hasPrefix("```") || plain.hasPrefix("$$") || plain.hasPrefix("![") || plain.hasPrefix("|") { continue }
            while let first = plain.first, "#>-*+ ".contains(first), plain.count > 1 { plain.removeFirst() }
            for task in ["[ ] ", "[x] ", "[X] "] where plain.hasPrefix(task) { plain.removeFirst(task.count) }
            plain = InlineRenderer.render(plain, font: .systemFont(ofSize: 15), color: .label).string
            if !plain.trimmingCharacters(in: .whitespaces).isEmpty { return plain }
        }
        return ""
    }
}

extension FileNode {
    /// A row for this file in a list.
    @MainActor
    func row(in workspace: Workspace, showsDetail: Bool = false) -> FileRow {
        FileRow(workspace: workspace, url: url, name: isLinked ? name : (kind == .folder ? workspace.folderName(url) : name), kind: kind,
                isInCloud: isInCloud, showsDetail: showsDetail)
    }
}

extension Workspace {
    /// What a folder shows, read when first asked for and again whenever files change in it.
    func visibleChildren(of folder: URL) -> [FileNode] {
        _ = treeVersion
        return node(for: folder)?.visibleChildren() ?? []
    }

    /// A row for any file, found again by its address.
    func row(for url: URL, showsDetail: Bool = false, favorite: Bool = false) -> FileRow {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let kind = FileKind(url: url, isDirectory: isFolder)
        let name = kind == .folder ? folderName(url) : SearchSection.displayName(url)
        let isLocation = locations.contains { $0.url == url.standardizedFileURL }
        let symbol = isLocation ? (Location.isICloudDriveRoot(url) || url.path == Location.iCloudDrivePath ? "icloud" : "externaldrive") : favorite && kind == .folder ? "star" : nil
        return FileRow(workspace: self, url: url, name: name, kind: kind, symbol: symbol, showsDetail: showsDetail)
    }
}

/// Dragging files onto folders: within Folio's locations they move, from other apps they are copied in.
struct FileDragAndDrop: ViewModifier {
    let workspace: Workspace
    let url: URL
    let isFolder: Bool
    var canDrag = true
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isFolder {
            dragged(content)
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter { $0.isFileURL && $0.standardizedFileURL != url.standardizedFileURL }
                    guard !files.isEmpty, !files.contains(where: { url.path.hasPrefix($0.path + "/") }) else { return false }
                    withAnimation { workspace.drop(files, into: url) }
                    return true
                } isTargeted: { isTargeted = $0 }
                .listRowBackground(isTargeted ? Color.accentColor.opacity(0.18) : nil)
        } else {
            dragged(content)
        }
    }

    @ViewBuilder
    private func dragged(_ content: Content) -> some View {
        if canDrag, !workspace.isLinkedFolder(url) {
            content.draggable(url)
        } else {
            content
        }
    }
}

extension View {
    func fileDragAndDrop(_ url: URL, isFolder: Bool, workspace: Workspace, canDrag: Bool = true) -> some View {
        modifier(FileDragAndDrop(workspace: workspace, url: url, isFolder: isFolder, canDrag: canDrag))
    }
}

/// Everything you can do with a file or folder, for its context menu and the ⋯ menu of an open file.
struct FileActions: View {
    let workspace: Workspace
    let url: URL
    /// Asks for the name of a new folder in this one.
    var newFolder: ((URL) -> Void)?

    var body: some View {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let kind = FileKind(url: url, isDirectory: isFolder)
        let isLinked = workspace.isLinkedFolder(url)
        let isLocation = workspace.locations.contains { $0.url == url.standardizedFileURL }
        if isFolder {
            Section {
                Button { workspace.newNote(in: url) } label: { Label("New Note", systemImage: "square.and.pencil") }
                if let newFolder {
                    Button { newFolder(url) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                }
            }
        } else if kind != .note {
            Button { workspace.quickLook(url) } label: { Label("Quick Look", systemImage: "eye") }
        }
        Section {
            if !isLinked, !isLocation {
                Button { workspace.renaming = url } label: { Label("Rename", systemImage: "pencil") }
                MoveToMenu(workspace: workspace, url: url)
                Button { workspace.duplicate(url) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            }
            let favorite = workspace.isFavorite(url)
            Button { withAnimation { workspace.toggleFavorite(url) } } label: {
                Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star")
            }
        }
        Section {
            if !isFolder {
                Button { workspace.copyLink(url) } label: { Label("Copy Link", systemImage: "link") }
            }
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        if isLocation, let location = workspace.locations.first(where: { $0.url == url.standardizedFileURL }) {
            Section {
                Button(role: .destructive) { workspace.removeLocation(location.id) } label: { Label("Remove from Folio", systemImage: "minus.circle") }
            }
        } else if !isLinked {
            Section {
                Button(role: .destructive) { workspace.moveToTrash(url) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }
}

extension Workspace {
    /// Deletes a file the way the Files app does: to Recently Deleted, or, where a place has none, for good after
    /// asking.
    func moveToTrash(_ url: URL) {
        guard !trash(url) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        deleting = url
    }
}

/// The search results as a list's content: Recent with an empty field, then Files, In Notes and PDFs, and New Note.
struct SearchResultsList: View {
    let workspace: Workspace
    let query: String
    var open: (SearchResult) -> Void

    var body: some View {
        let sections = SearchSection.sections(for: query, in: workspace)
        ForEach(sections) { section in
            Section {
                ForEach(section.items) { item in
                    Button { open(item.result) } label: { row(item) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if case .file(let url) = item.result { FileActions(workspace: workspace, url: url) }
                        }
                }
            } header: {
                if let title = section.title { Text(title) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SearchItem) -> some View {
        if let kind = item.kind {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    if let snippet = item.snippet {
                        Text(highlighted(snippet, match: item.match))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let place = item.place {
                        Text(place).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: item.isInCloud ? "icloud.and.arrow.down" : kind.symbol)
                    .foregroundStyle(kind == .folder ? Color.accentColor : kind == .note || kind == .other ? Color.secondary : Color.theme(kind.tint))
            }
            .contentShape(Rectangle())
        } else {
            Label(item.title, systemImage: "square.and.pencil")
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
        }
    }

    /// The words you searched for, in the colour of the text.
    private func highlighted(_ snippet: String, match: Range<String.Index>?) -> AttributedString {
        var text = AttributedString(snippet)
        if let match, let range = Range(match, in: text) {
            text[range].foregroundColor = .primary
            text[range].font = .subheadline.weight(.semibold)
        }
        return text
    }
}

/// The alerts every screen needs: renaming, naming a new folder, deleting for good, and things that went wrong.
struct FileAlerts: ViewModifier {
    @Bindable var workspace: Workspace
    @Binding var newFolderIn: URL?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: Binding(get: { workspace.renaming != nil }, set: { if !$0 { workspace.renaming = nil } })) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                Button("Cancel", role: .cancel) { workspace.renaming = nil }
                Button("Rename") {
                    if let url = workspace.renaming { rename(url) }
                    workspace.renaming = nil
                }
                .keyboardShortcut(.defaultAction)
            }
            .onChange(of: workspace.renaming) { _, url in
                if let url { name = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
            }
            .alert("New Folder", isPresented: Binding(get: { newFolderIn != nil }, set: { if !$0 { newFolderIn = nil } })) {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.sentences)
                Button("Cancel", role: .cancel) { newFolderIn = nil }
                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let parent = newFolderIn { workspace.newFolder(in: parent, named: trimmed.isEmpty ? "New Folder" : trimmed) }
                    newFolderIn = nil
                }
                .keyboardShortcut(.defaultAction)
            } message: {
                Text("Enter a name for this folder.")
            }
            .onChange(of: newFolderIn) { _, folder in if folder != nil { name = "" } }
            .alert(deleteTitle, isPresented: Binding(get: { workspace.deleting != nil }, set: { if !$0 { workspace.deleting = nil } })) {
                Button("Cancel", role: .cancel) { workspace.deleting = nil }
                Button("Delete", role: .destructive) {
                    if let url = workspace.deleting { workspace.deleteImmediately(url) }
                    workspace.deleting = nil
                }
            } message: {
                Text("This place has no Recently Deleted folder, so it is deleted right away. You can’t undo this.")
            }
            .alert(workspace.problem?.title ?? "", isPresented: Binding(get: { workspace.problem != nil }, set: { if !$0 { workspace.problem = nil } }), presenting: workspace.problem) { _ in
                Button("OK") { workspace.problem = nil }
            } message: { problem in
                Text(problem.message)
            }
    }

    private var deleteTitle: String {
        guard let url = workspace.deleting else { return "" }
        return "Delete “\(SearchSection.displayName(url))” immediately?"
    }

    private func rename(_ url: URL) {
        var target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        guard !target.isEmpty, target != current else { return }
        // A name typed with the extension of a file that has one keeps just one extension.
        if !url.pathExtension.isEmpty, (target as NSString).pathExtension.lowercased() == url.pathExtension.lowercased() {
            target = (target as NSString).deletingPathExtension
        }
        workspace.rename(url, to: target)
    }
}
#endif
