import AppKit
import SwiftUI

/// The app's state: the locations, the file that is open, where you have been, and everything you can do with files.
@MainActor
@Observable
public final class Workspace: NSObject {
    public static let shared = Workspace()

    public private(set) var locations: [Location] = []
    private(set) var roots: [UUID: FileNode] = [:]
    /// The file shown on the right.
    public private(set) var currentURL: URL?
    public private(set) var note: NoteDocument?
    @ObservationIgnored public let editor = EditorController()
    let index = SearchIndex()

    private(set) var history: [URL] = []
    private(set) var historyIndex = -1
    /// Back and Forward by swiping, and where you were in each note, to come back to.
    @ObservationIgnored let pages = PageSwiper()
    @ObservationIgnored private var places: [URL: EditorController.Place] = [:]
    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []
    /// The folders hidden from the sidebar: kept in iCloud, or only for this run with locations given on the command line.
    private(set) var hidden = HiddenFolders(defaults: nil, cloud: nil)

    /// The search field in the toolbar.
    @ObservationIgnored lazy var search = SearchController(workspace: self)
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isSidebarVisible: Bool {
        get { columnVisibility != .detailOnly }
        set { columnVisibility = newValue ? .all : .detailOnly }
    }
    /// The outline of the open note, on the right.
    var isOutlineVisible = UserDefaults.standard.object(forKey: "showsOutline") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isOutlineVisible, forKey: "showsOutline") }
    }
    /// The open note's headings and length, and where in it you are.
    private(set) var outline: [OutlineHeading] = []
    private(set) var stats = NoteStats()
    private(set) var currentHeading: Int?
    /// True once the note's title has scrolled up under the toolbar, which then shows it.
    private(set) var isTitleScrolledAway = false
    /// The folder selected in the sidebar, where ⌘N puts a note when no note is open.
    var selectedFolder: URL?
    /// Locations given on the command line for this run only (tests, the demo library).
    @ObservationIgnored private var temporaryLocations = false
    @ObservationIgnored private var isStarted = false
    /// Brings the main window up (set by the window, which SwiftUI opens).
    @ObservationIgnored var showWindow: (() -> Void)?

    @ObservationIgnored weak var sidebar: SidebarController?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var pendingFolders = Set<String>()
    @ObservationIgnored private var refreshScheduled = false
    /// `.assets` files the open note used, so the ones it drops can go to the Trash when you leave it.
    @ObservationIgnored private var assetsInUse = Set<String>()

    public override init() {
        super.init()
        editor.delegate = self
        pages.workspace = self
    }

    // MARK: - Starting

    /// Reads the locations, once: when the window first appears, or before that when a folder is opened from the Dock.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        #if DEBUG
        // The welcome screen, for screenshots, without touching the locations you added.
        if UserDefaults.standard.bool(forKey: "NotebookWelcome") {
            temporaryLocations = true
            return
        }
        #endif
        favorites = UserDefaults.standard.stringArray(forKey: "favorites") ?? []
        recents = UserDefaults.standard.stringArray(forKey: "recents") ?? []
        if let path = UserDefaults.standard.string(forKey: "NotebookLibrary") {
            // A folder given on the command line (tests, screenshots): used for this run, not remembered.
            temporaryLocations = true
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "NotebookDemo") { DemoLibrary.create(at: url) }
            #endif
            locations = [Location(id: UUID(), name: UserDefaults.standard.string(forKey: "NotebookLibraryName") ?? url.lastPathComponent, path: url.path, bookmark: nil)]
            favorites = []
            recents = []
        } else {
            locations = LocationStore.load()
            hidden = HiddenFolders()
        }
        #if DEBUG
        if temporaryLocations, UserDefaults.standard.bool(forKey: "NotebookDemo"), let library = locations.first {
            for path in DemoLibrary.hiddenFolders { hidden.set(hiddenKey(for: library.url.appendingPathComponent(path)), hidden: true) }
        }
        #endif
        hidden.onChange = { [weak self] in self?.hiddenFoldersChanged() }
        locationsChanged()
        if !temporaryLocations, let last = UserDefaults.standard.string(forKey: "lastOpened"), FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
        }
    }

    private func locationsChanged() {
        for index in locations.indices { locations[index].findLinkedFolders() }
        var fresh: [UUID: FileNode] = [:]
        for location in locations {
            let root = roots[location.id] ?? FileNode(url: location.url, kind: .folder, parent: nil)
            if root.linked != location.linked {
                root.linked = location.linked
                root.reload()
            }
            fresh[location.id] = root
        }
        roots = fresh
        watcher = FileWatcher(paths: locations.flatMap { $0.folders.map(\.url.path) }) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        updateHiddenPaths()
        index.rebuild(locations)
        sidebar?.reloadAll()
    }

    public func addLocation(_ url: URL) {
        let url = url.standardizedFileURL
        guard !locations.contains(where: { $0.path == url.path }) else { return }
        locations.append(LocationStore.make(for: url))
        if !temporaryLocations { LocationStore.save(locations) }
        locationsChanged()
    }

    public func removeLocation(_ id: UUID) {
        locations.removeAll { $0.id == id }
        if !temporaryLocations { LocationStore.save(locations) }
        locationsChanged()
    }

    /// Asks for iCloud Drive (or another folder) and adds it.
    public func chooseLocation(iCloud: Bool) {
        let start = iCloud ? URL(fileURLWithPath: Location.iCloudDrivePath, isDirectory: true) : FileManager.default.homeDirectoryForCurrentUser
        guard let url = LocationStore.choose(startingIn: start, message: iCloud ? "Click Open to show iCloud Drive in Notebook." : nil) else { return }
        addLocation(url)
    }

    /// A folder from File › Open or the Dock icon: shown where it is in the sidebar, or added as a location of its own
    /// (iCloud Drive, say) when no location has it yet.
    public func openFolder(_ url: URL) {
        start()
        let url = url.standardizedFileURL
        if location(containing: url) == nil { addLocation(url) }
        showWindow?()
        isSidebarVisible = true
        open(url)
    }

    func root(for location: Location) -> FileNode? { roots[location.id] }

    func location(containing url: URL) -> Location? {
        locations.first { $0.contains(url) }
    }

    /// iCloud Drive's Desktop and the like: shown in a location, but not to be renamed, moved or thrown away from it.
    func isLinkedFolder(_ url: URL) -> Bool {
        locations.contains { $0.isLinkedFolder(url) }
    }

    /// A folder's name as the sidebar shows it: a location's, a linked folder's, or the folder's own.
    func folderName(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let location = locations.first(where: { $0.url.path == path }) { return location.name }
        if let linked = locations.lazy.flatMap(\.linked).first(where: { $0.url.path == path }) { return linked.name }
        return url.lastPathComponent
    }

    /// The nodes from a location's top down to a file, as far as they go: reading folders on the way, or with
    /// `reading` false only through folders already read. `complete` says whether they reach the file.
    func nodes(to url: URL, reading: Bool = true) -> (location: Location, nodes: [FileNode], complete: Bool)? {
        let path = url.standardizedFileURL.path
        guard let location = location(containing: url), let root = roots[location.id], let folder = location.folder(containing: path) else { return nil }
        var nodes = [root]
        func children(of node: FileNode) -> [FileNode] {
            reading || node.hasLoadedChildren ? node.loadedChildren() : []
        }
        if let linked = folder.linked {
            guard let top = children(of: root).first(where: { $0.isLinked && $0.url.path == linked.url.path }) else { return (location, nodes, false) }
            nodes.append(top)
        }
        for component in path.dropFirst(folder.url.path.count).split(separator: "/") {
            guard let next = children(of: nodes[nodes.count - 1]).first(where: { !$0.isLinked && $0.url.lastPathComponent == component }) else {
                return (location, nodes, false)
            }
            nodes.append(next)
        }
        return (location, nodes, true)
    }

    /// The node for a file, reading folders on the way to it.
    func node(for url: URL) -> FileNode? {
        guard let found = nodes(to: url), found.complete else { return nil }
        return found.nodes.last
    }

    // MARK: - Files changing

    private func filesChanged(_ paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            pendingFolders.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            pendingFolders.insert(url.standardizedFileURL.path)
        }
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.applyFileChanges() }
        }
    }

    private func applyFileChanges() {
        refreshScheduled = false
        let folders = pendingFolders
        pendingFolders = []
        var changed: [FileNode] = []
        var indexFolders: [URL] = []
        for path in folders {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if url.lastPathComponent == ".assets" { continue }
            indexFolders.append(url)
            if let node = existingNode(for: url), node.hasLoadedChildren, node.reload() { changed.append(node) }
        }
        if !changed.isEmpty { sidebar?.reload(changed) }
        index.refresh(folders: indexFolders, locations: locations)
        editor.refreshLinks()
        if let current = currentURL, !FileManager.default.fileExists(atPath: current.path), note == nil {
            currentURL = nil
        }
    }

    /// A node that is already in the tree, without reading anything.
    private func existingNode(for url: URL) -> FileNode? {
        guard let found = nodes(to: url, reading: false), found.complete else { return nil }
        return found.nodes.last
    }

    // MARK: - Opening

    public func open(_ url: URL, recordHistory: Bool = true, focusTitle: Bool = false) {
        let target = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) || target.lastPathComponent.hasSuffix(".icloud") else { return }
        if isDirectory.boolValue, !isPackage(target) {
            selectedFolder = target
            sidebar?.reveal(target, select: true)
            return
        }
        if target == currentURL {
            if focusTitle { editor.focusTitle() }
            return
        }
        pages.willOpen(target)
        if note != nil, let current = currentURL { places[current] = editor.place }
        leaveCurrentNote()
        if (try? target.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: target)
        }
        currentURL = target
        selectedFolder = nil
        if FileKind(url: target, isDirectory: false) == .note {
            let document = NoteDocument(url: target)
            document.onExternalChange = { [weak self] text in self?.editor.reload(text: text) }
            document.onMove = { [weak self] url in self?.noteMoved(to: url) }
            document.onDelete = { [weak self] in self?.currentNoteDeleted() }
            note = document
            assetsInUse = FileOperations.assetNames(in: document.text)
            editor.load(text: document.text, folder: target.deletingLastPathComponent(), title: focusTitle ? "" : document.url.deletingPathExtension().lastPathComponent,
                        meta: meta(for: document), focusTitle: focusTitle)
            if !recordHistory, let place = places[target] { restore(place) }
            // The editor only reports changes, and a Quick Look file in between cleared the outline here.
            editorOutlineDidChange(editor)
            editorPositionDidChange(editor)
            if !focusTitle { DispatchQueue.main.async { [weak self] in self?.focusEditorIfNothingElse() } }
        } else {
            note = nil
            outline = []
            stats = NoteStats()
            currentHeading = nil
            isTitleScrolledAway = false
        }
        if recordHistory {
            if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
            history.append(target)
            historyIndex = history.count - 1
        }
        recents.removeAll { $0 == target.path }
        recents.insert(target.path, at: 0)
        recents = Array(recents.prefix(8))
        if !temporaryLocations {
            UserDefaults.standard.set(recents, forKey: "recents")
            UserDefaults.standard.set(target.path, forKey: "lastOpened")
        }
        // Only the selection moves in the sidebar: nothing above it changes, so nothing jumps.
        sidebar?.reveal(target, select: true)
    }

    /// Back and Forward come back to where you were, once the note is in the window again.
    private func restore(_ place: EditorController.Place) {
        if editor.view.window != nil {
            editor.restore(place)
        } else {
            DispatchQueue.main.async { [weak self] in self?.editor.restore(place) }
        }
    }

    private func focusEditorIfNothingElse() {
        guard let window = editor.textView.window else { return }
        if window.firstResponder === window || window.firstResponder == nil || window.firstResponder is NSOutlineView {
            return
        }
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    /// Saves the note being left; a new note left empty goes away, and pictures it no longer uses go to the Trash.
    private func leaveCurrentNote() {
        guard let note else { return }
        note.update(text: editor.text)
        note.close()
        let folder = note.url.deletingLastPathComponent()
        let dropped = assetsInUse.subtracting(FileOperations.assetNames(in: note.text))
        if !dropped.isEmpty { FileOperations.cleanUpAssets(in: folder, candidates: dropped) }
        if note.isNew, note.isEmpty, note.url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled") {
            _ = FileOperations.trash(note.url)
        }
        self.note = nil
    }

    func meta(for document: NoteDocument) -> String {
        guard let date = document.modified else { return "" }
        return "Edited " + Self.relative(date)
    }

    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide)) + " at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoForward: Bool { historyIndex < history.count - 1 }

    public func goBack() {
        while canGoBack {
            historyIndex -= 1
            if FileManager.default.fileExists(atPath: history[historyIndex].path) {
                open(history[historyIndex], recordHistory: false)
                return
            }
        }
    }

    public func goForward() {
        while canGoForward {
            historyIndex += 1
            if FileManager.default.fileExists(atPath: history[historyIndex].path) {
                open(history[historyIndex], recordHistory: false)
                return
            }
        }
    }

    private func noteMoved(to url: URL) {
        currentURL = url.standardizedFileURL
        editor.setTitle(url.deletingPathExtension().lastPathComponent)
        sidebar?.reveal(url, select: true)
    }

    private func currentNoteDeleted() {
        note = nil
        currentURL = nil
    }

    // MARK: - Favourites and recents

    func isFavorite(_ url: URL) -> Bool { favorites.contains(url.standardizedFileURL.path) }

    func toggleFavorite(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let index = favorites.firstIndex(of: path) { favorites.remove(at: index) } else { favorites.append(path) }
        if !temporaryLocations { UserDefaults.standard.set(favorites, forKey: "favorites") }
        sidebar?.reloadSections()
    }

    var favoriteURLs: [URL] {
        favorites.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The files opened last, newest first, without the one that is open: for File › Open Recent and search.
    var recentURLs: [URL] {
        recents.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) && $0 != currentURL }
    }

    func clearRecents() {
        recents = []
        if !temporaryLocations { UserDefaults.standard.set(recents, forKey: "recents") }
    }

    private func replacePath(_ old: URL, with new: URL) {
        let oldPath = old.standardizedFileURL.path
        let newPath = new.standardizedFileURL.path
        func fix(_ path: String) -> String {
            path == oldPath ? newPath : path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path
        }
        hiddenFolderMoved(from: old, to: new)
        favorites = favorites.map(fix)
        recents = recents.map(fix)
        history = history.map { URL(fileURLWithPath: fix($0.path)) }
        if let current = currentURL { currentURL = URL(fileURLWithPath: fix(current.path)) }
        if !temporaryLocations {
            UserDefaults.standard.set(favorites, forKey: "favorites")
            UserDefaults.standard.set(recents, forKey: "recents")
        }
    }

    // MARK: - Making and changing files

    /// Where a new note goes: next to the open one, into the folder selected in the sidebar, or the Inbox.
    var folderForNewNote: URL? {
        if let selectedFolder { return selectedFolder }
        if let currentURL { return currentURL.deletingLastPathComponent() }
        return inboxFolder
    }

    var inboxFolder: URL? {
        guard let location = locations.first else { return nil }
        let inbox = location.url.appendingPathComponent("Inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    public func newNote(in folder: URL? = nil, title: String? = nil) {
        guard let folder = folder ?? folderForNewNote, let url = FileOperations.createNote(in: folder, title: title ?? "Untitled") else { return }
        refreshNow(folder)
        open(url, focusTitle: title == nil)
        note?.isNew = title == nil
    }

    public func newFolder(in parent: URL? = nil) {
        guard let parent = parent ?? selectedFolder ?? currentURL?.deletingLastPathComponent() ?? locations.first?.url,
              let url = FileOperations.createFolder(in: parent) else { return }
        refreshNow(parent)
        sidebar?.reveal(url, select: true)
        sidebar?.beginRenaming(url)
    }

    /// Reads a folder again right away, without waiting for the file system to report the change.
    func refreshNow(_ folder: URL) {
        if let node = existingNode(for: folder), node.hasLoadedChildren, node.reload() { sidebar?.reload([node]) }
        index.refresh(folders: [folder], locations: locations)
    }

    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        guard !isLinkedFolder(url) else { NSSound.beep(); return nil }
        let isNote = FileKind(url: url, isDirectory: false) == .note
        let oldName = url.deletingPathExtension().lastPathComponent
        if url == currentURL { note?.saveNow() }
        guard let renamed = FileOperations.rename(url, to: name) else {
            let alert = NSAlert()
            alert.messageText = "The name “\(name)” is already taken."
            alert.informativeText = "Please choose a different name."
            if let window = editor.textView.window ?? NSApp.mainWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return nil
        }
        if note?.url.standardizedFileURL == url.standardizedFileURL { note?.moved(to: renamed) }
        replacePath(url, with: renamed)
        refreshNow(url.deletingLastPathComponent())
        if url.standardizedFileURL == note?.url.standardizedFileURL || renamed.standardizedFileURL == currentURL {
            editor.setTitle(renamed.deletingPathExtension().lastPathComponent)
        }
        if isNote, let location = location(containing: renamed) {
            let newName = renamed.deletingPathExtension().lastPathComponent
            for folder in location.folders {
                _ = FileOperations.updateLinks(from: oldName, to: newName, under: folder.url, skipping: nil)
            }
        }
        sidebar?.reveal(renamed, select: renamed == currentURL)
        return renamed
    }

    func move(_ url: URL, into folder: URL) {
        guard !isLinkedFolder(url) else { NSSound.beep(); return }
        let destination = FileOperations.uniqueURL(in: folder, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
        if url == currentURL { note?.saveNow() }
        // A note takes the pictures it uses along into the new folder's .assets.
        var text: String?
        if FileKind(url: url, isDirectory: false) == .note { text = NoteDocument.read(url) }
        guard let moved = FileOperations.move(url, to: destination) else { NSSound.beep(); return }
        if note?.url.standardizedFileURL == url.standardizedFileURL { note?.moved(to: moved) }
        if let text, url.deletingLastPathComponent() != folder {
            let assets = FileOperations.assetNames(in: text)
            for name in assets {
                let source = url.deletingLastPathComponent().appendingPathComponent(".assets").appendingPathComponent(name)
                let target = folder.appendingPathComponent(".assets").appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: source, to: target)
            }
            FileOperations.cleanUpAssets(in: url.deletingLastPathComponent(), candidates: assets)
        }
        replacePath(url, with: moved)
        refreshNow(url.deletingLastPathComponent())
        refreshNow(folder)
        if moved == currentURL, let note {
            editor.load(text: editor.text, folder: folder, title: moved.deletingPathExtension().lastPathComponent, meta: meta(for: note))
        }
        sidebar?.reveal(moved, select: moved == currentURL)
    }

    /// Where a file can be moved: every folder of every location, in order, with how deep it is.
    func moveTargets(for url: URL) -> [(location: Location, folders: [(url: URL, name: String, depth: Int)])] {
        let all = index.folders(matching: "", limit: .max)
        let source = url.standardizedFileURL.path
        return locations.map { location in
            // Linked folders (iCloud Drive's Desktop) sit at the top, under their own names.
            let folders = location.folders.flatMap { folder -> [(url: URL, name: String, depth: Int, path: String)] in
                let base = folder.url.path
                let prefix = folder.linked.map { $0.name + "/" } ?? ""
                var found = all.compactMap { entry -> (url: URL, name: String, depth: Int, path: String)? in
                    let path = entry.url.standardizedFileURL.path
                    guard path.hasPrefix(base + "/"), path != source, !path.hasPrefix(source + "/") else { return nil }
                    let relative = prefix + String(path.dropFirst(base.count + 1))
                    return (entry.url, entry.name, relative.split(separator: "/").count - 1, relative)
                }
                if let linked = folder.linked, base != source, !base.hasPrefix(source + "/"), !index.isHidden(linked.url) {
                    found.append((linked.url, linked.name, 0, linked.name))
                }
                return found
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { (url: $0.url, name: $0.name, depth: $0.depth) }
            return (location, [(url: location.url, name: location.name, depth: -1)] + folders)
        }
    }

    func trash(_ url: URL) {
        guard !isLinkedFolder(url) else { NSSound.beep(); return }
        let wasCurrent = url == currentURL || (currentURL?.path.hasPrefix(url.path + "/") ?? false)
        if wasCurrent {
            note?.close()
            note = nil
            currentURL = nil
        }
        guard FileOperations.trash(url) else { NSSound.beep(); return }
        hiddenFolderMoved(from: url, to: nil)
        refreshNow(url.deletingLastPathComponent())
        favorites.removeAll { $0 == url.path }
        if wasCurrent, let previous = history.last(where: { $0 != url && FileManager.default.fileExists(atPath: $0.path) }) {
            open(previous, recordHistory: false)
        }
    }

    func duplicate(_ url: URL) {
        guard !isLinkedFolder(url), let copy = FileOperations.duplicate(url) else { return }
        refreshNow(url.deletingLastPathComponent())
        sidebar?.reveal(copy, select: false)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyLink(_ url: URL) {
        let name = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("[[\(name)]]", forType: .string)
    }

    /// The note in the window you are working in: a file window's, or this window's.
    func activeEditor() -> (editor: EditorController, title: String, window: NSWindow?)? {
        if let key = NSApp.keyWindow, let controller = key.windowController as? FileWindowController {
            return (controller.editor, controller.url.deletingPathExtension().lastPathComponent, key)
        }
        guard note != nil else { return nil }
        return (editor, currentTitle, editor.textView.window)
    }

    func export(as format: NoteExporter.Format) {
        guard let active = activeEditor() else { NSSound.beep(); return }
        NoteExporter.export(active.editor, title: active.title, as: format, from: active.window)
    }

    func printNote() {
        guard let active = activeEditor() else { NSSound.beep(); return }
        NoteExporter.print(active.editor, title: active.title, from: active.window)
    }

    /// The open file's name as you read it: notes without their extension.
    var currentTitle: String {
        guard let currentURL else { return "Notebook" }
        return FileKind(url: currentURL, isDirectory: false) == .note ? currentURL.deletingPathExtension().lastPathComponent : currentURL.lastPathComponent
    }

    /// Saves everything; called when the app goes to the background or quits.
    public func saveAll() {
        guard let note else { return }
        note.update(text: editor.text)
        note.saveNow()
    }

    func resolveConflict(_ resolution: NoteDocument.Resolution) {
        guard let note else { return }
        let text = note.resolve(resolution)
        editor.reload(text: text)
    }

    // MARK: - Quick Look

    func quickLook(_ url: URL) {
        QuickLookPanel.shared.show(url)
    }
}

// MARK: - EditorControllerDelegate

extension Workspace: EditorControllerDelegate {
    public func editorTextDidChange(_ editor: EditorController) {
        note?.update(text: editor.text)
    }

    public func editorOutlineDidChange(_ editor: EditorController) {
        outline = editor.outline
        stats = editor.stats
    }

    public func editorPositionDidChange(_ editor: EditorController) {
        if currentHeading != editor.currentHeading { currentHeading = editor.currentHeading }
        if isTitleScrolledAway != editor.isTitleScrolledAway { isTitleScrolledAway = editor.isTitleScrolledAway }
    }

    public func editor(_ editor: EditorController, open target: LinkTarget.Kind) {
        switch target {
        case .url(let string):
            if let url = URL(string: string), url.scheme != nil { NSWorkspace.shared.open(url) }
        case .file(let url):
            if FileManager.default.fileExists(atPath: url.path) { open(url) } else { NSSound.beep() }
        case .note(let target):
            if let url = index.resolve(target, from: currentURL) {
                open(url)
            } else if let folder = currentURL?.deletingLastPathComponent() ?? folderForNewNote {
                // A link to a note that doesn't exist yet makes it.
                let name = target.components(separatedBy: "#").first ?? target
                if let url = FileOperations.createNote(in: folder, title: name) {
                    refreshNow(folder)
                    open(url)
                    editor.focusText()
                }
            }
        }
    }

    public func editor(_ editor: EditorController, quickLook url: URL) {
        quickLook(url)
    }

    public func editor(_ editor: EditorController, commitTitle title: String) {
        guard let note else { return }
        let current = note.url.deletingPathExtension().lastPathComponent
        let wanted = title.isEmpty ? current : title
        if wanted.isEmpty || FileOperations.fileName(from: wanted) == current {
            editor.setTitle(current)
            return
        }
        if rename(note.url, to: wanted) == nil { editor.setTitle(current) }
        note.isNew = false
    }

    public func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion] {
        index.linkSuggestions(query, from: currentURL)
    }

    public func editor(_ editor: EditorController, resolve target: String) -> URL? {
        index.resolve(target, from: currentURL)
    }

    public func editorNoteName(_ editor: EditorController) -> String {
        currentURL?.deletingPathExtension().lastPathComponent ?? "Note"
    }
}
