#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// A screen of the iPhone's navigation: a folder or a file. It is an object rather than an address, so that a note
/// renamed or moved while it is open keeps its screen, which follows it to its new name.
@MainActor
@Observable
final class Page: Hashable {
    var url: URL
    let isFolder: Bool

    init(url: URL, isFolder: Bool) {
        self.url = url.standardizedFileURL
        self.isFolder = isFolder
    }

    nonisolated static func == (a: Page, b: Page) -> Bool { a === b }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The iPhone, and an iPad window too narrow for a sidebar: one folder per screen, as in the Files app, and a file
/// on a screen of its own. Search and a new note are at the bottom, as in Notes.
struct PhoneBrowser: View {
    @Bindable var workspace: Workspace
    @State private var path: [Page] = []
    @State private var newFolderIn: URL?

    var body: some View {
        NavigationStack(path: $path) {
            HomeScreen(workspace: workspace, newFolderIn: $newFolderIn)
                .navigationDestination(for: Page.self) { page in
                    if page.isFolder {
                        FolderScreen(workspace: workspace, page: page, newFolderIn: $newFolderIn)
                    } else {
                        DocumentScreen(workspace: workspace, url: page.url)
                    }
                }
        }
        .modifier(FileAlerts(workspace: workspace, newFolderIn: $newFolderIn))
        .onAppear {
            // Back where you were: in the note you had open, with its folders behind it.
            if let url = workspace.currentURL, path.isEmpty { path = folders(to: url) + [Page(url: url, isFolder: false)] }
        }
        .onChange(of: path) { _, path in pathChanged(path) }
        .onChange(of: workspace.currentURL) { _, url in fileChanged(url) }
        .onChange(of: workspace.folderRequest?.id) { _, _ in
            guard let folder = workspace.folderRequest?.url, path.last?.url != folder else { return }
            path.append(Page(url: folder, isFolder: true))
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .folioDebug)) { notification in
            switch notification.userInfo?["command"] as? String {
            case "back": if !path.isEmpty { path.removeLast() }
            case "home": path = []
            case "push": if let argument = notification.userInfo?["argument"] as? String, let root = workspace.locations.first?.url {
                path.append(Page(url: root.appendingPathComponent(argument), isFolder: true))
            }
            default: break
            }
        }
        #endif
        .onChange(of: workspace.relocation?.id) { _, _ in
            guard let relocation = workspace.relocation else { return }
            for page in path {
                let old = relocation.from.path
                if page.url.path == old {
                    page.url = relocation.to
                } else if page.url.path.hasPrefix(old + "/") {
                    page.url = URL(fileURLWithPath: relocation.to.path + page.url.path.dropFirst(old.count))
                }
            }
        }
    }

    /// Back to a folder leaves the note (it is saved); back to a note opens it again where you were.
    private func pathChanged(_ path: [Page]) {
        if let top = path.last, !top.isFolder {
            if workspace.currentURL != top.url { workspace.reopen(top.url) }
        } else if workspace.currentURL != nil {
            workspace.closeFile()
        }
    }

    /// A file opened from a link, from search or as a new note gets a screen of its own; one deleted goes away.
    private func fileChanged(_ url: URL?) {
        guard let url else {
            if let top = path.last, !top.isFolder { path.removeLast() }
            return
        }
        if let top = path.last, !top.isFolder, top.url == url { return }
        path.append(Page(url: url, isFolder: false))
    }

    /// The folders from the top of a location down to the one a file is in.
    private func folders(to url: URL) -> [Page] {
        guard let found = workspace.nodes(to: url) else { return [] }
        return found.nodes.filter(\.isFolder).map { Page(url: $0.url, isFolder: true) }
    }
}

/// The first screen: favourites, what you opened last, and what is in each location, as Notes lists its folders.
struct HomeScreen: View {
    @Bindable var workspace: Workspace
    @Binding var newFolderIn: URL?
    @State private var query = ""
    @State private var isSearching = false
    @State private var showsSettings = false
    @State private var addsLocation = false

    var body: some View {
        List {
            if isSearching {
                SearchResultsList(workspace: workspace, query: query) { open($0) }
            } else {
                let favorites = workspace.favoriteURLs
                if !favorites.isEmpty {
                    Section("Favorites") {
                        ForEach(favorites, id: \.self) { url in
                            link(url, row: workspace.row(for: url, favorite: true))
                        }
                    }
                }
                let recents = Array(workspace.recentURLs.prefix(3))
                if !recents.isEmpty {
                    Section("Recent") {
                        ForEach(recents, id: \.self) { url in
                            link(url, row: workspace.row(for: url, showsDetail: true))
                        }
                    }
                }
                ForEach(workspace.locations) { location in
                    Section {
                        let children = workspace.visibleChildren(of: location.url)
                        ForEach(children, id: \.url) { node in
                            NavigationLink(value: Page(url: node.url, isFolder: node.isFolder)) { node.row(in: workspace) }
                                .fileDragAndDrop(node.url, isFolder: node.isFolder, workspace: workspace)
                                .contextMenu { FileActions(workspace: workspace, url: node.url) { newFolderIn = $0 } }
                        }
                        if children.isEmpty {
                            Text("Empty").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(location.name)
                            .contextMenu { FileActions(workspace: workspace, url: location.url) { newFolderIn = $0 } }
                    }
                }
                Section {
                    Button { addsLocation = true } label: {
                        Label("Add Location", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("Folio")
        .searchable(text: $query, isPresented: $isSearching, prompt: "Search")
        .onSubmit(of: .search) { submitSearch() }
        .refreshable { workspace.refresh(thoroughly: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { addsLocation = true } label: { Label("Add Location", systemImage: "folder.badge.plus") }
                    Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { workspace.newNote(in: workspace.inboxFolder) } label: { Label("New Note", systemImage: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showsSettings) { TouchSettings(workspace: workspace) }
        .folderImporter(isPresented: $addsLocation, workspace: workspace)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .folioDebug)) { notification in
            let argument = notification.userInfo?["argument"] as? String ?? ""
            switch notification.userInfo?["command"] as? String {
            case "search":
                isSearching = true
                query = argument
            case "endsearch":
                query = ""
                isSearching = false
            case "settings": showsSettings = argument != "hide"
            default: break
            }
        }
        #endif
    }

    private func link(_ url: URL, row: FileRow) -> some View {
        let isFolder = row.kind == .folder
        return NavigationLink(value: Page(url: url, isFolder: isFolder)) { row }
            .contextMenu { FileActions(workspace: workspace, url: url) { newFolderIn = $0 } }
    }

    private func open(_ result: SearchResult) {
        switch result {
        case .file(let url): workspace.open(url)
        case .newNote(let title): workspace.newNote(title: title)
        }
    }

    /// Return opens the best match, as on the Mac.
    private func submitSearch() {
        guard let first = SearchSection.sections(for: query, in: workspace).first?.items.first else { return }
        open(first.result)
    }
}

/// A folder's files and folders, newest notes with how they start.
struct FolderScreen: View {
    @Bindable var workspace: Workspace
    let page: Page
    @Binding var newFolderIn: URL?
    @State private var query = ""
    @State private var isSearching = false
    @Bindable private var settings = FolioSettings.shared

    var body: some View {
        let children = workspace.visibleChildren(of: page.url)
        List {
            if isSearching {
                SearchResultsList(workspace: workspace, query: query) { open($0) }
            } else {
                ForEach(children, id: \.url) { node in
                    NavigationLink(value: Page(url: node.url, isFolder: node.isFolder)) {
                        node.row(in: workspace, showsDetail: true)
                    }
                    .fileDragAndDrop(node.url, isFolder: node.isFolder, workspace: workspace)
                    .contextMenu { FileActions(workspace: workspace, url: node.url) { newFolderIn = $0 } }
                    .swipeActions(edge: .trailing) {
                        if !node.isLinked {
                            Button(role: .destructive) { workspace.moveToTrash(node.url) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        let favorite = workspace.isFavorite(node.url)
                        Button { workspace.toggleFavorite(node.url) } label: {
                            Label(favorite ? "Unfavorite" : "Favorite", systemImage: favorite ? "star.slash" : "star")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .overlay {
            if children.isEmpty, !isSearching {
                ContentUnavailableView {
                    Label("No Notes", systemImage: "doc.text")
                } description: {
                    Text("Notes and files you put in this folder show here.")
                } actions: {
                    Button("New Note") { workspace.newNote(in: page.url) }
                }
            }
        }
        .animation(.default, value: children.map(\.url))
        .navigationTitle(workspace.folderName(page.url))
        .searchable(text: $query, isPresented: $isSearching, prompt: "Search")
        .onSubmit(of: .search) {
            if let first = SearchSection.sections(for: query, in: workspace).first?.items.first { open(first.result) }
        }
        .refreshable { workspace.refreshNow(page.url) }
        .onAppear { workspace.selectedFolder = page.url }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section {
                        Button { newFolderIn = page.url } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    }
                    Section {
                        Toggle(isOn: $settings.showsOnlyNotes) { Label("Show Only Notes", systemImage: "doc.text") }
                        Toggle(isOn: $settings.foldersFirst) { Label("Keep Folders on Top", systemImage: "folder") }
                    }
                    Section {
                        let favorite = workspace.isFavorite(page.url)
                        Button { workspace.toggleFavorite(page.url) } label: {
                            Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "star.slash" : "star")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button { workspace.newNote(in: page.url) } label: { Label("New Note", systemImage: "square.and.pencil") }
            }
        }
    }

    private func open(_ result: SearchResult) {
        switch result {
        case .file(let url): workspace.open(url)
        case .newNote(let title): workspace.newNote(in: page.url, title: title)
        }
    }
}

extension View {
    /// The Files app's folder picker, adding the folder you choose as a location.
    func folderImporter(isPresented: Binding<Bool>, workspace: Workspace) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            workspace.addLocation(url)
        }
    }
}
#endif
