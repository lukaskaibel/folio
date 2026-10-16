#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
    #if os(macOS)
    /// Back and Forward by swiping.
    @ObservationIgnored let pages = PageSwiper()
    #endif
    /// Where you were in each note, to come back to.
    @ObservationIgnored private var places: [URL: EditorController.Place] = [:]
    private(set) var favorites: [String] = []
    private(set) var recents: [String] = []
    /// The folders hidden from the sidebar: kept in iCloud, or only for this run with locations given on the command line.
    private(set) var hidden = HiddenFolders(defaults: nil, cloud: nil)
    /// The reminders of notes: kept in iCloud too, or only for this run with locations given on the command line.
    private(set) var reminders = Reminders(defaults: nil, cloud: nil)
    /// Counts the reminders whose time came, so what shows them turns red then, without anything else changing.
    var remindersDue = 0
    @ObservationIgnored var dueTimer: Timer?
    #if DEBUG
    /// The sample notes' reminders, shown but never scheduled: a run on the sample notes leaves no notification behind.
    @ObservationIgnored var unscheduledReminders = Set<UUID>()
    #endif

    #if os(macOS)
    /// The search field in the toolbar.
    @ObservationIgnored lazy var search = SearchController(workspace: self)
    #endif
    var columnVisibility: NavigationSplitViewVisibility = .all
    var isSidebarVisible: Bool {
        get { columnVisibility != .detailOnly }
        set { columnVisibility = newValue ? .all : .detailOnly }
    }
    /// The outline of the open note, on the right. On the iPad it starts hidden, leaving the note the room.
    var isOutlineVisible = UserDefaults.standard.object(forKey: "showsOutline") as? Bool ?? Workspace.showsOutlineAtFirst {
        didSet { UserDefaults.standard.set(isOutlineVisible, forKey: "showsOutline") }
    }
    #if os(macOS)
    private static let showsOutlineAtFirst = true
    #else
    private static let showsOutlineAtFirst = false
    #endif

    /// The open note's headings and length, and where in it you are.
    private(set) var outline: [OutlineHeading] = []
    private(set) var stats = NoteStats()
    private(set) var currentHeading: Int?
    /// True once the note's title has scrolled up under the toolbar, which then shows it.
    private(set) var isTitleScrolledAway = false
    /// The note is in drawing mode: the pencil in the toolbar is on and the drawing tools are out.
    private(set) var isDrawing = false
    /// While drawing: whether Undo and Redo have strokes to take back or bring again.
    private(set) var canUndoDrawing = false
    private(set) var canRedoDrawing = false
    /// The folder selected in the sidebar, where ⌘N puts a note when no note is open.
    var selectedFolder: URL?
    /// Locations given on the command line for this run only (tests, the demo library).
    @ObservationIgnored private(set) var temporaryLocations = false
    @ObservationIgnored private(set) var isStarted = false
    /// Brings the main window up (set by the window, which SwiftUI opens).
    @ObservationIgnored var showWindow: (() -> Void)?

    #if os(macOS)
    @ObservationIgnored weak var sidebar: SidebarController?
    /// Remind Me… while it is open, so another one takes its place.
    @ObservationIgnored weak var reminderPopover: NSPopover?
    #else
    /// Counts changes to the folders that have been read, so the lists showing them read them again.
    private(set) var treeVersion = 0
    /// A folder to show, opened from search or a link: the iPhone goes into it, the iPad's sidebar opens down to it.
    private(set) var folderRequest: (url: URL, id: UUID)?
    /// A file or folder to show in the sidebar, and to select there.
    private(set) var revealRequest: (url: URL, select: Bool, id: UUID)?
    /// A new folder to name, or a file to rename, asked for in an alert.
    var renaming: URL?
    /// The file shown in Quick Look over everything.
    var quickLookURL: URL?
    /// Something that couldn't be done, for an alert.
    var problem: Problem?
    /// Counts ⌘F, which puts the caret in the search field.
    var searchRequest = 0
    /// A file to delete for good, once you said so, where there is no Recently Deleted to put it in.
    var deleting: URL?
    /// A note to set a reminder for, in a sheet.
    var reminderRequest: ReminderRequest?
    /// What each note looked like when you went on from it, shown while the screen of the note you go on to slides
    /// over it, and while you swipe back to it. There is only one editor, and it is on the screen in front.
    @ObservationIgnored var pageSnapshots: [URL: UIView] = [:]
    /// True while the keyboard is up for the note or its title.
    private(set) var isEditing = false
    #endif
    /// The last file or folder renamed or moved, so screens showing it follow it to its new place.
    private(set) var relocation: (from: URL, to: URL, id: UUID)?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Reads folders off the main thread.
    @ObservationIgnored let reader = FolderReader()
    /// Counts the lookups of the locations (`survey`), and what waits until the newest is done.
    @ObservationIgnored private var surveys = 0
    @ObservationIgnored private var surveysDone = 0
    @ObservationIgnored private var afterSurvey: [() -> Void] = []
    /// The file to show in the sidebar once the folders down to it have been read.
    @ObservationIgnored private var revealing: URL?
    @ObservationIgnored private var pendingFolders = Set<String>()
    @ObservationIgnored private var refreshScheduled = false
    /// `.assets` files the open note used, so the ones it drops can go to the Trash when you leave it.
    @ObservationIgnored private var assetsInUse = Set<String>()
    /// Every folder Move To offers, in order (`prepareMoveFolders`).
    @ObservationIgnored private var moveFolders: MoveFolders?
    @ObservationIgnored private var preparingMoveFolders: MoveFolders.Key?
    /// Counts the times Move To's folders were sorted again in the background, for the menus that show them.
    private var moveFoldersVersion = 0

    public override init() {
        super.init()
        editor.delegate = self
        index.onBuilt = { [weak self] in
            self?.editor.refreshLinks()
            // Notes moved in the Finder can be found by their names now.
            self?.scheduleReminders()
        }
        index.onFoldersChanged = { [weak self] in self?.prepareMoveFolders() }
        #if os(macOS)
        pages.workspace = self
        #endif
    }

    // MARK: - Starting

    /// Reads the locations, once: when the window first appears, or before that when a folder is opened from the Dock.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        #if os(macOS)
        MoveToSubmenu.fillSwiftUIMenus(for: self)
        #endif
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
            reminders = Reminders()
        }
        #if DEBUG
        if temporaryLocations, UserDefaults.standard.bool(forKey: "NotebookDemo"), let library = locations.first {
            for path in DemoLibrary.hiddenFolders { hidden.set(hiddenKey(for: library.url.appendingPathComponent(path)), hidden: true) }
            for (path, date) in DemoLibrary.reminders() {
                unscheduledReminders.insert(reminders.set(note: hiddenKey(for: library.url.appendingPathComponent(path)), date: date).id)
            }
        }
        #endif
        hidden.onChange = { [weak self] in self?.hiddenFoldersChanged() }
        reminders.onChange = { [weak self] in self?.remindersChanged() }
        watchForDueReminders()
        let last = temporaryLocations ? nil : UserDefaults.standard.string(forKey: "lastOpened")
        locationsChanged(resolving: true, reading: last.map { [$0] } ?? [])
        if let last, FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
        }
    }

    /// Shows the locations at once, by name and with the files already read, and looks at them again off the main
    /// thread (`survey`).
    private func locationsChanged(resolving: Bool = false, reading files: [String] = [], new: UUID? = nil) {
        var fresh: [UUID: FileNode] = [:]
        for location in locations {
            fresh[location.id] = roots[location.id] ?? FileNode(url: location.url, kind: .folder, parent: nil)
        }
        roots = fresh
        // First, so the sidebar doesn't read a new location's top itself, without its linked folders.
        survey(resolving: resolving, reading: files, new: new)
        sidebarReloadAll()
    }

    /// Looks at every location off the main thread: where a saved one is now (`resolving`), its bookmark if it is
    /// `new`, iCloud Drive's linked folders, and the files at its top, with the folders that were open and those down
    /// to `files` for a location not read yet. Then shows it all at once, starts watching and builds the index. Reading
    /// folders meanwhile waits for it, so nothing is read twice or without its linked folders.
    private func survey(resolving: Bool, reading files: [String], new: UUID?) {
        surveys += 1
        let count = surveys
        var folders = UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? []
        for file in files {
            var folder = URL(fileURLWithPath: file).deletingLastPathComponent()
            while folder.pathComponents.count > 1 {
                folders.append(folder.path)
                folder = folder.deletingLastPathComponent()
            }
        }
        let jobs = locations.map { location in
            LocationSurvey.Job(id: location.id, url: location.url, bookmark: resolving ? location.bookmark : nil, isNew: location.id == new,
                               linked: location.linked, isRead: roots[location.id]?.hasLoadedChildren ?? false, folders: folders)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let surveys = jobs.map(LocationSurvey.run)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.surveyed(surveys, count: count) }
            }
        }
    }

    private func surveyed(_ surveys: [LocationSurvey], count: Int) {
        var changed: [FileNode] = []
        var reloadsAll = false
        var saves = false
        for survey in surveys {
            guard let index = locations.firstIndex(where: { $0.id == survey.id }) else { continue }
            if survey.url.path != locations[index].path {
                // Moved since last time: the bookmark found it.
                locations[index].path = survey.url.path
                roots[survey.id] = FileNode(url: locations[index].url, kind: .folder, parent: nil)
                reloadsAll = true
                saves = true
            }
            if let bookmark = survey.bookmark {
                locations[index].bookmark = bookmark
                saves = true
            }
            if let name = survey.name, name != locations[index].name {
                locations[index].name = name
                saves = true
                reloadsAll = true
            }
            locations[index].linked = survey.linked
            guard let root = roots[survey.id] else { continue }
            root.linked = survey.linked
            if let top = survey.top, root.apply(top) { changed.append(root) }
            for folder in survey.folders {
                if let node = node(for: URL(fileURLWithPath: folder.path), reading: false), node.isFolder, node.apply(folder.listing) {
                    changed.append(node)
                }
            }
        }
        if saves, !temporaryLocations { LocationStore.save(locations) }
        // An older lookup's files are as good as any, but only the newest knows every location.
        surveysDone = max(surveysDone, count)
        if reloadsAll { sidebarReloadAll() } else if !changed.isEmpty { sidebarReload(changed) }
        guard count == self.surveys else { return }
        watcher = FileWatcher(paths: locations.flatMap { $0.folders.map(\.url.path) }) { [weak self] paths in
            MainActor.assumeIsolated { self?.filesChanged(paths) }
        }
        updateHiddenPaths()
        index.rebuild(locations)
        scheduleReminders()
        let waiting = afterSurvey
        afterSurvey = []
        waiting.forEach { $0() }
    }

    /// True while the locations are being looked up (`survey`).
    var isSurveying: Bool { surveysDone < surveys }

    /// Does something once the locations have been looked up, with iCloud Drive's linked folders: at once if they have.
    func whenSurveyed(_ action: @escaping () -> Void) {
        if isSurveying { afterSurvey.append(action) } else { action() }
    }

    /// True once they have been, and their tops read.
    var hasReadLocations: Bool { surveysDone > 0 && !isSurveying }

    /// Adds a folder to the sidebar at once, by its name; its files show a moment later, read off the main thread
    /// like everything inside it, so even all of iCloud Drive never makes you wait.
    public func addLocation(_ url: URL) {
        let url = url.standardizedFileURL
        guard !locations.contains(where: { $0.path == url.path }) else { return }
        let location = LocationStore.make(for: url)
        locations.append(location)
        if !temporaryLocations { LocationStore.save(locations) }
        locationsChanged(new: location.id)
        #if os(macOS)
        // At the end of a long sidebar it would be out of sight: once its files show, it scrolls into view.
        reveal(url, select: false)
        #endif
    }

    /// Of folders dragged onto the sidebar, the ones it could add: folders it doesn't show yet. Nil when the drag
    /// has anything else in it, such as a file or a folder already in a location.
    func newLocations(in urls: [URL]) -> [URL]? {
        let urls = urls.map(\.standardizedFileURL)
        let fresh = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !isPackage(url) && location(containing: url) == nil
        }
        return !fresh.isEmpty && fresh.count == urls.count ? fresh : nil
    }

    /// Folders dropped on the sidebar, each a location of its own, as folders dropped in the Finder's sidebar are.
    @discardableResult
    func addLocations(_ urls: [URL]) -> Bool {
        guard let fresh = newLocations(in: urls) else { return false }
        fresh.forEach(addLocation)
        return true
    }

    public func removeLocation(_ id: UUID) {
        locations.removeAll { $0.id == id }
        if !temporaryLocations { LocationStore.save(locations) }
        locationsChanged()
    }

    #if os(macOS)
    /// Asks for iCloud Drive (or another folder) and adds it.
    public func chooseLocation(iCloud: Bool) {
        let start = iCloud ? URL(fileURLWithPath: Location.iCloudDrivePath, isDirectory: true) : FileManager.default.homeDirectoryForCurrentUser
        guard let url = LocationStore.choose(startingIn: start, message: iCloud ? "Click Open to show iCloud Drive in Notebook." : nil) else { return }
        addLocation(url)
    }
    #endif

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

    /// The node for a file: reading folders on the way to it, or with `reading` false only if they have been read.
    func node(for url: URL, reading: Bool = true) -> FileNode? {
        guard let found = nodes(to: url, reading: reading), found.complete else { return nil }
        return found.nodes.last
    }

    /// The folders from a location's top down to the one a file is in, worked out from its address alone.
    func folders(to url: URL) -> (location: Location, folders: [URL])? {
        let path = url.standardizedFileURL.path
        guard let location = location(containing: url), let folder = location.folder(containing: path) else { return nil }
        guard path != location.url.path else { return (location, []) }
        var folders = [location.url]
        if folder.linked != nil, path != folder.url.path { folders.append(folder.url) }
        var current = folder.url
        for component in path.dropFirst(folder.url.path.count).split(separator: "/").dropLast() {
            current = current.appendingPathComponent(String(component), isDirectory: true)
            folders.append(current)
        }
        return (location, folders)
    }

    // MARK: - Reading folders

    /// Reads folders off the main thread and shows what they hold: those not read yet, or with `again` (files changed
    /// in them) all of them. A folder already waiting to be read ahead of time is read next instead.
    func read(_ nodes: [FileNode], again: Bool = false, ahead: Bool = false) {
        guard !isSurveying else {
            afterSurvey.append { [weak self] in self?.read(nodes, again: again, ahead: ahead) }
            return
        }
        var folders: [FileNode] = []
        for node in nodes where node.isFolder && (again || !node.hasLoadedChildren) {
            if !again, reader.isReading(node.url) {
                if !ahead { reader.hurry(node.url) }
            } else {
                folders.append(node)
            }
        }
        guard !folders.isEmpty else { return }
        read(folders.map { FolderReader.Request(url: $0.url, linked: $0.linked) }, ahead: ahead, then: nil)
    }

    /// Reads a folder's contents ahead of time, after everything else, so they are there when you open it.
    func prefetch(_ node: FileNode) {
        guard node.isFolder, !node.hasLoadedChildren else { return }
        read([node], ahead: true)
    }

    func prefetch(_ folder: URL) {
        if let node = node(for: folder, reading: false) { prefetch(node) }
    }

    /// Reads the folders down to a file that haven't been read yet (with the file itself, if it is a folder and
    /// `including`), then does `done`: at once when there is nothing to read. Without `done`, folders already being
    /// read are left to that.
    func readFolders(to url: URL, including: Bool = false, then done: (() -> Void)? = nil) {
        guard !isSurveying else {
            afterSurvey.append { [weak self] in self?.readFolders(to: url, including: including, then: done) }
            return
        }
        guard let found = folders(to: url) else { done?(); return }
        var folders = found.folders
        if including { folders.append(url.standardizedFileURL) }
        let missing = folders.filter { node(for: $0, reading: false)?.hasLoadedChildren != true && (done != nil || !reader.isReading($0)) }
        guard !missing.isEmpty else { done?(); return }
        let root = roots[found.location.id]
        read(missing.map { FolderReader.Request(url: $0, linked: $0 == root?.url ? root?.linked ?? [] : []) }, then: done)
    }

    private func read(_ requests: [FolderReader.Request], ahead: Bool = false, then done: (() -> Void)?) {
        reader.read(requests, ahead: ahead) { [weak self] results in
            guard let self else { return }
            var changed: [FileNode] = []
            for result in results {
                guard let listing = result.listing, let node = node(for: URL(fileURLWithPath: result.path), reading: false), node.isFolder else { continue }
                if node.apply(listing) { changed.append(node) }
            }
            if !changed.isEmpty { sidebarReload(changed) }
            done?()
        }
    }

    /// Whether a folder's contents have been read, for lists that say "Empty" only when it is.
    func hasRead(_ folder: URL) -> Bool {
        node(for: folder, reading: false)?.hasLoadedChildren ?? false
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

    /// Reads the folders where files changed again, off the main thread: iCloud changes thousands of files while it
    /// syncs, and the sidebar and search follow without the window waiting.
    private func applyFileChanges() {
        refreshScheduled = false
        let folders = pendingFolders
        pendingFolders = []
        var changed: [FileNode] = []
        var indexFolders: [URL] = []
        for path in folders {
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent == ".assets" { continue }
            indexFolders.append(url)
            if let node = existingNode(for: url), node.isFolder, node.hasLoadedChildren { changed.append(node) }
        }
        read(changed, again: true)
        index.refresh(folders: indexFolders, locations: locations)
        remindersMayHaveChanged(in: indexFolders)
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
            reveal(target, select: true)
            #if os(iOS)
            folderRequest = (target, UUID())
            #endif
            return
        }
        if target == currentURL {
            if focusTitle { editor.focusTitle() }
            return
        }
        #if os(macOS)
        pages.willOpen(target)
        #else
        keepSnapshot()
        #endif
        keepPlace()
        leaveCurrentNote()
        if (try? target.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded {
            try? FileManager.default.startDownloadingUbiquitousItem(at: target)
        }
        currentURL = target
        selectedFolder = nil
        if FileKind(url: target, isDirectory: false) == .note {
            // A note still in iCloud shows its title at once and its text when it has come down; the window doesn't
            // wait for it.
            let document = NoteDocument(url: target)
            let place = recordHistory ? nil : places[target]
            document.onExternalChange = { [weak self] text in self?.editor.reload(text: text) }
            document.onMove = { [weak self] url in self?.noteMoved(to: url) }
            document.onDelete = { [weak self] in self?.currentNoteDeleted() }
            document.onSave = { [weak self, weak document] in
                guard let self, let document else { return }
                self.noteSaved(document.url)
            }
            document.onLoad = { [weak self, weak document] _ in
                guard let self, let document, self.note === document else { return }
                self.show(document, focusTitle: focusTitle, place: place)
            }
            note = document
            show(document, focusTitle: focusTitle, place: place)
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
        reveal(target, select: true)
    }

    /// Puts the open note in the editor: its text, or only its title while the text is on its way. Back and Forward
    /// come back to `place` once the text is there.
    private func show(_ document: NoteDocument, focusTitle: Bool, place: EditorController.Place?) {
        assetsInUse = FileOperations.assetNames(in: document.text)
        editor.load(text: document.isLoaded ? document.text : nil, folder: document.url.deletingLastPathComponent(),
                    title: focusTitle ? "" : document.url.deletingPathExtension().lastPathComponent, meta: meta(for: document), focusTitle: focusTitle)
        updateReminderLine()
        if document.isLoaded, let place { restore(place) }
        // The editor only reports changes, and a Quick Look file in between cleared the outline here.
        editorOutlineDidChange(editor)
        editorPositionDidChange(editor)
    }

    /// Remembers where you are in the note you leave, to come back there. A note whose text hasn't come yet keeps the
    /// place it had.
    private func keepPlace() {
        guard let note, note.isLoaded, let current = currentURL else { return }
        places[current] = editor.place
    }

    #if os(iOS)
    /// Leaves the file that is open, for the folder it is in: the iPhone's Back.
    public func closeFile() {
        guard currentURL != nil else { return }
        keepSnapshot()
        keepPlace()
        leaveCurrentNote()
        currentURL = nil
        outline = []
        stats = NoteStats()
        currentHeading = nil
        isTitleScrolledAway = false
    }

    /// Opens a note again, where you left it: going back to it on the iPhone.
    public func reopen(_ url: URL) {
        open(url, recordHistory: false)
    }

    /// The folder Notebook keeps on this device, shown in the Files app under On My iPhone › Notebook.
    nonisolated public static var onDeviceFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// A file or folder handed over by another app (the Files app's Open With, a share): a folder becomes a location,
    /// a file opens, from its folder if Notebook shows that.
    public func openFromOutside(_ url: URL) {
        start()
        guard url.isFileURL else { return }
        _ = url.startAccessingSecurityScopedResource()
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if location(containing: url) == nil { addLocation(url) }
        }
        open(url)
    }

    /// Reads the folders on screen again: when Notebook comes back to the front and when you pull a list down. Pulling
    /// down (`thoroughly`) reads every folder for search again too.
    public func refresh(thoroughly: Bool = false) {
        guard isStarted, !locations.isEmpty else { return }
        var loaded: [FileNode] = []
        func visit(_ node: FileNode) {
            guard let children = node.children else { return }
            loaded.append(node)
            children.filter(\.isFolder).forEach(visit)
        }
        roots.values.forEach(visit)
        let folders = loaded.map(\.url)
        read(loaded, again: true)
        if thoroughly { index.rebuild(locations) } else { index.refresh(folders: folders, locations: locations) }
        editor.refreshLinks()
    }

    /// Keeps a picture of the note on screen, for its screen to show once the editor has moved on.
    private func keepSnapshot() {
        guard note != nil, let current = currentURL, editor.isInWindow,
              let snapshot = editor.view.snapshotView(afterScreenUpdates: false) else { return }
        pageSnapshots[current] = snapshot
        if pageSnapshots.count > 12, let old = pageSnapshots.keys.first(where: { $0 != current }) { pageSnapshots[old] = nil }
    }
    #endif

    /// Back and Forward come back to where you were, once the note is in the window again.
    private func restore(_ place: EditorController.Place) {
        if editor.isInWindow {
            editor.restore(place)
        } else {
            DispatchQueue.main.async { [weak self] in self?.editor.restore(place) }
        }
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    /// Saves the note being left; a new note left empty goes away, and pictures it no longer uses go to the Trash.
    private func leaveCurrentNote() {
        guard let note else { return }
        editor.endDrawing()
        #if os(iOS)
        // Back while typing a new name: the name counts, as it would once the title is left.
        if editor.isEditingTitle { editor.commitTitle() }
        #endif
        note.update(text: editor.text)
        note.close()
        let folder = note.url.deletingLastPathComponent()
        let dropped = assetsInUse.subtracting(FileOperations.assetNames(in: note.text))
        if !dropped.isEmpty { FileOperations.cleanUpAssets(in: folder, candidates: dropped) }
        if note.isNew, note.isEmpty, note.url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled") {
            #if os(iOS)
            // Where there is no Recently Deleted, an empty note made a moment ago goes for good: nothing is lost.
            if !FileOperations.trash(note.url) { _ = FileOperations.delete(note.url) }
            #else
            _ = FileOperations.trash(note.url)
            #endif
            refreshNow(folder)
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

    /// The open note was renamed or moved somewhere else, in the Finder or on another device: its reminder follows.
    private func noteMoved(to url: URL) {
        if let old = currentURL {
            relocation = (old, url.standardizedFileURL, UUID())
            reminderMoved(from: old, to: url.standardizedFileURL)
        }
        currentURL = url.standardizedFileURL
        editor.setTitle(url.deletingPathExtension().lastPathComponent)
        reveal(url, select: true)
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
        #if os(macOS)
        sidebar?.reloadSections()
        #endif
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
        reminderMoved(from: old, to: new)
        favorites = favorites.map(fix)
        recents = recents.map(fix)
        history = history.map { URL(fileURLWithPath: fix($0.path)) }
        relocation = (old.standardizedFileURL, new.standardizedFileURL, UUID())
        if let current = currentURL { currentURL = URL(fileURLWithPath: fix(current.path)) }
        #if os(iOS)
        pageSnapshots = Dictionary(pageSnapshots.map { (URL(fileURLWithPath: fix($0.key.path)), $0.value) }, uniquingKeysWith: { a, _ in a })
        #endif
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

    /// A new folder, named "New Folder" to be renamed at once, or with the name already chosen.
    @discardableResult
    public func newFolder(in parent: URL? = nil, named name: String? = nil) -> URL? {
        guard let parent = parent ?? selectedFolder ?? currentURL?.deletingLastPathComponent() ?? locations.first?.url,
              let url = FileOperations.createFolder(in: parent, name: name.map(FileOperations.fileName(from:)) ?? "New Folder") else { return nil }
        refreshNow(parent)
        reveal(url, select: true) { [weak self] in
            #if os(macOS)
            self?.sidebar?.beginRenaming(url)
            #endif
        }
        return url
    }

    /// Reads a folder again right away, without waiting for the file system to report the change.
    func refreshNow(_ folder: URL) {
        if let node = existingNode(for: folder), node.hasLoadedChildren, node.reload() { sidebarReload([node]) }
        index.refresh(folders: [folder], locations: locations)
    }

    /// Renames a file or folder. Links to a renamed note in other notes follow it, unless it is a new note getting its
    /// first name, which nothing links to yet.
    @discardableResult
    func rename(_ url: URL, to name: String, updatingLinks: Bool = true) -> URL? {
        guard !isLinkedFolder(url) else { beep(); return nil }
        let isNote = FileKind(url: url, isDirectory: false) == .note
        let oldName = url.deletingPathExtension().lastPathComponent
        if url == currentURL { note?.saveNow() }
        guard let renamed = FileOperations.rename(url, to: name) else {
            report("The name “\(name)” is already taken.", "Please choose a different name.")
            return nil
        }
        if note?.url.standardizedFileURL == url.standardizedFileURL { note?.moved(to: renamed) }
        replacePath(url, with: renamed)
        refreshNow(url.deletingLastPathComponent())
        if url.standardizedFileURL == note?.url.standardizedFileURL || renamed.standardizedFileURL == currentURL {
            editor.setTitle(renamed.deletingPathExtension().lastPathComponent)
        }
        if isNote, updatingLinks, let location = location(containing: renamed) {
            let newName = renamed.deletingPathExtension().lastPathComponent
            let roots = location.folders.map(\.url)
            // In the background: it reads every note of the location, which in a large folder in iCloud Drive takes
            // long (and waits for notes still to download). The notes it changes come back as changes on disk.
            Task.detached(priority: .utility) {
                for root in roots {
                    _ = FileOperations.updateLinks(from: oldName, to: newName, under: root, skipping: nil)
                }
            }
        }
        reveal(renamed, select: renamed == currentURL)
        return renamed
    }

    func move(_ url: URL, into folder: URL) {
        guard !isLinkedFolder(url) else { beep(); return }
        let destination = FileOperations.uniqueURL(in: folder, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
        if url == currentURL { note?.saveNow() }
        // A note takes the pictures it uses along into the new folder's .assets.
        var text: String?
        if FileKind(url: url, isDirectory: false) == .note { text = NoteDocument.read(url) }
        guard let moved = FileOperations.move(url, to: destination) else { beep(); return }
        if note?.url.standardizedFileURL == url.standardizedFileURL { note?.moved(to: moved) }
        if let text, url.deletingLastPathComponent() != folder {
            let assets = FileOperations.assetNames(in: text)
            for name in FileOperations.withDrawingStrokes(assets) {
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
            editor.load(text: note.isLoaded ? editor.text : nil, folder: folder, title: moved.deletingPathExtension().lastPathComponent, meta: meta(for: note))
            updateReminderLine()
        }
        reveal(moved, select: moved == currentURL)
    }

    /// Files dropped on a folder: moved there from elsewhere in Notebook's locations, copied from anywhere else (or
    /// when `copying`, Option on the Mac).
    func drop(_ urls: [URL], into folder: URL, copying: Bool = false) {
        for url in urls {
            if location(containing: url) != nil, !copying {
                if url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL { move(url, into: folder) }
            } else {
                let destination = FileOperations.uniqueURL(in: folder, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
                let accessing = url.startAccessingSecurityScopedResource()
                try? FileManager.default.copyItem(at: url, to: destination)
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
        }
        refreshNow(folder)
    }

    /// Where a file can be moved: every folder of every location, in order, with how deep it is.
    func moveTargets(for url: URL) -> [(location: Location, folders: [(url: URL, name: String, depth: Int)])] {
        let source = url.standardizedFileURL.path
        return currentMoveFolders().targets.map { target in
            (target.location, target.folders.compactMap { folder in
                folder.depth >= 0 && (folder.path == source || folder.path.hasPrefix(source + "/")) ? nil : (folder.url, folder.name, folder.depth)
            })
        }
    }

    /// What the folders Move To lists now were sorted from: when it changes, so do they.
    var moveFoldersInUse: MoveFolders.Key { currentMoveFolders().key }

    private var moveFoldersKey: MoveFolders.Key {
        MoveFolders.Key(folders: index.folderVersion, locations: locations, hidden: index.hiddenPaths)
    }

    /// Move To's folders as they are now. After folders came or went they are as they were for the moment it takes to
    /// sort the new ones, as the index itself is behind the disk for a moment; a folder hidden or a location added
    /// shows at once.
    private func currentMoveFolders() -> MoveFolders {
        _ = moveFoldersVersion
        let key = moveFoldersKey
        if let moveFolders, moveFolders.key.locations == key.locations, moveFolders.key.hidden == key.hidden {
            if moveFolders.key != key { prepareMoveFolders() }
            return moveFolders
        }
        let made = MoveFolders(key, folders: index.allFolders())
        moveFolders = made
        preparingMoveFolders = nil
        return made
    }

    /// Sorts Move To's folders again in the background, after folders came or went: for a whole iCloud Drive that is
    /// thousands of them.
    private func prepareMoveFolders() {
        let key = moveFoldersKey
        guard moveFolders?.key != key, preparingMoveFolders != key else { return }
        preparingMoveFolders = key
        let folders = index.allFolders()
        Task.detached(priority: .utility) {
            let made = MoveFolders(key, folders: folders)
            await MainActor.run {
                guard self.preparingMoveFolders == key else { return }
                self.preparingMoveFolders = nil
                self.moveFolders = made
                self.moveFoldersVersion += 1
            }
        }
    }

    /// Moves a file or folder to the Trash. Returns false when that can't be done (the place has no Trash).
    @discardableResult
    func trash(_ url: URL) -> Bool {
        guard !isLinkedFolder(url) else { beep(); return false }
        let wasCurrent = url == currentURL || (currentURL?.path.hasPrefix(url.path + "/") ?? false)
        if wasCurrent {
            note?.close()
            note = nil
            currentURL = nil
        }
        guard FileOperations.trash(url) else { beep(); return false }
        hiddenFolderMoved(from: url, to: nil)
        reminderMoved(from: url, to: nil)
        refreshNow(url.deletingLastPathComponent())
        favorites.removeAll { $0 == url.path }
        #if os(macOS)
        if wasCurrent, let previous = history.last(where: { $0 != url && FileManager.default.fileExists(atPath: $0.path) }) {
            open(previous, recordHistory: false)
        }
        #endif
        return true
    }

    #if os(iOS)
    /// Deletes for good, after you agreed to it: only where there is no Recently Deleted.
    func deleteImmediately(_ url: URL) {
        if url == currentURL || (currentURL?.path.hasPrefix(url.path + "/") ?? false) { closeFile() }
        guard FileOperations.delete(url) else { beep(); return }
        hiddenFolderMoved(from: url, to: nil)
        reminderMoved(from: url, to: nil)
        refreshNow(url.deletingLastPathComponent())
        favorites.removeAll { $0 == url.path }
    }
    #endif

    func duplicate(_ url: URL) {
        guard !isLinkedFolder(url), let copy = FileOperations.duplicate(url) else { return }
        refreshNow(url.deletingLastPathComponent())
        reveal(copy, select: false)
    }

    func copyLink(_ url: URL) {
        let name = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        copyToPasteboard("[[\(name)]]")
    }

    #if os(macOS)
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
    #endif

    /// The open file's name as you read it: notes without their extension.
    var currentTitle: String {
        guard let currentURL else { return "Notebook" }
        return FileKind(url: currentURL, isDirectory: false) == .note ? currentURL.deletingPathExtension().lastPathComponent : currentURL.lastPathComponent
    }

    /// Saves everything; called when the app goes to the background or (`quitting`) quits, when drawings are written
    /// before it goes on.
    public func saveAll(quitting: Bool = false) {
        editor.saveDrawingsNow(waiting: quitting)
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
        #if os(macOS)
        QuickLookPanel.shared.show(url)
        #else
        quickLookURL = url
        #endif
    }

    // MARK: - What the window shows

    /// Something that couldn't be done: an alert, on the Mac over the window.
    func report(_ title: String, _ message: String) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = editor.textView.window ?? NSApp.mainWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
        #else
        problem = Problem(title: title, message: message)
        #endif
    }

    /// Opens the folders down to a file in the sidebar, and selects it there: once they have been read, then `done`.
    func reveal(_ url: URL, select: Bool, then done: (() -> Void)? = nil) {
        revealing = url
        readFolders(to: url) { [weak self] in
            guard let self, self.revealing == url else { return }
            #if os(macOS)
            sidebar?.reveal(url, select: select)
            #else
            revealRequest = (url, select, UUID())
            #endif
            done?()
        }
    }

    func sidebarReloadAll() {
        #if os(macOS)
        sidebar?.reloadAll()
        #else
        treeVersion += 1
        #endif
    }

    private func sidebarReload(_ nodes: [FileNode]) {
        #if os(macOS)
        sidebar?.reload(nodes)
        #else
        treeVersion += 1
        #endif
    }
}

/// Something that couldn't be done, and why.
public struct Problem: Identifiable, Equatable {
    public let id = UUID()
    public var title: String
    public var message: String
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

    public func editorDrawingDidChange(_ editor: EditorController) {
        if isDrawing != editor.isDrawing { isDrawing = editor.isDrawing }
        if canUndoDrawing != editor.canUndoDrawing { canUndoDrawing = editor.canUndoDrawing }
        if canRedoDrawing != editor.canRedoDrawing { canRedoDrawing = editor.canRedoDrawing }
    }

    public func editorEditingDidChange(_ editor: EditorController) {
        #if os(iOS)
        // Asked once the focus has settled, so going from the title to the text doesn't count as stopping.
        DispatchQueue.main.async { [weak self] in
            let editing = editor.isFocused || editor.isEditingTitle
            if self?.isEditing != editing { self?.isEditing = editing }
        }
        #endif
    }

    public func editor(_ editor: EditorController, open target: LinkTarget.Kind) {
        switch target {
        case .url(let string):
            if let url = URL(string: string), url.scheme != nil { openExternally(url) }
        case .file(let url):
            if FileManager.default.fileExists(atPath: url.path) { open(url) } else { beep() }
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
        // A new note's title left empty keeps its placeholder, rather than "Untitled" to type over.
        if title.isEmpty, note.isNew { return }
        let wanted = title.isEmpty ? current : title
        if wanted.isEmpty || FileOperations.fileName(from: wanted) == current {
            editor.setTitle(current)
            return
        }
        if rename(note.url, to: wanted, updatingLinks: !note.isNew) == nil { editor.setTitle(current) }
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

    public func editorShowReminder(_ editor: EditorController) {
        guard let currentURL, note != nil else { return }
        askForReminder(currentURL)
    }
}
