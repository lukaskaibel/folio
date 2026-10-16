import XCTest
@testable import NotebookKit

/// iCloud Drive as the Finder shows it: with Desktop, Documents and the folders of apps that share theirs, which all
/// live outside iCloud Drive's own folder. Built here as a stand-in, next to a library folder for the other location.
@MainActor
final class LocationTests: XCTestCase {
    private var base: URL!
    private var drive: URL!
    private var desktop: URL { base.appendingPathComponent("Desktop") }
    private var plan: URL { desktop.appendingPathComponent("Trip/Plan.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-icloud-\(UUID().uuidString)").standardizedFileURL
        let containers = base.appendingPathComponent("Mobile Documents")
        drive = containers.appendingPathComponent("com~apple~CloudDocs")
        try make(drive.appendingPathComponent("Papers"))
        try make(desktop.appendingPathComponent("Trip"))
        try "# Plan\n".write(to: plan, atomically: true, encoding: .utf8)
        // The system's links to Desktop and Documents are hidden; a link made by hand isn't.
        let link = drive.appendingPathComponent("Desktop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
        XCTAssertEqual(lchflags(link.path, UInt32(UF_HIDDEN)), 0)
        try FileManager.default.createSymbolicLink(at: drive.appendingPathComponent("Shortcut"), withDestinationURL: desktop)
        // Apps that share their iCloud folder have it visible; the others' are hidden.
        try make(containers.appendingPathComponent("iCloud~md~obsidian/Documents/Vault"))
        try make(containers.appendingPathComponent("com~apple~mail/Documents"))
        XCTAssertEqual(chflags(containers.appendingPathComponent("com~apple~mail").path, UInt32(UF_HIDDEN)), 0)
        try make(containers.appendingPathComponent("iCloud~com~example~nodocuments"))
        UserDefaults.standard.set(drive.path, forKey: "NotebookICloudDrive")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "NotebookICloudDrive")
        UserDefaults.standard.removeObject(forKey: "NotebookLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A workspace with a library folder (for this run only), then iCloud Drive opened as File › Open does.
    private func makeWorkspace() throws -> Workspace {
        let library = base.appendingPathComponent("Library")
        try make(library)
        UserDefaults.standard.set(library.path, forKey: "NotebookLibrary")
        let workspace = Workspace()
        workspace.start()
        workspace.openFolder(drive)
        return workspace
    }

    func testICloudDriveLinksDesktopAndSharedAppFolders() {
        let links = Location.iCloudDriveLinks(in: drive)
        XCTAssertEqual(links.map(\.name).sorted(), ["Desktop", "Obsidian"])
        XCTAssertEqual(links.first { $0.name == "Desktop" }?.url.path, desktop.path)
        XCTAssertEqual(links.first { $0.name == "Obsidian" }?.url.lastPathComponent, "Documents")
    }

    func testOtherFoldersLinkNothingAndLinksAreNotSaved() throws {
        var papers = Location(id: UUID(), name: "Papers", path: drive.appendingPathComponent("Papers").path, bookmark: nil)
        papers.findLinkedFolders()
        XCTAssertTrue(papers.linked.isEmpty)

        var drive = Location(id: UUID(), name: "iCloud Drive", path: drive.path, bookmark: nil)
        drive.findLinkedFolders()
        XCTAssertEqual(drive.linked.count, 2)
        let saved = try JSONDecoder().decode(Location.self, from: JSONEncoder().encode(drive))
        XCTAssertEqual(saved.path, drive.path)
        XCTAssertTrue(saved.linked.isEmpty, "found again on every launch")
    }

    func testSidebarShowsLinkedFoldersAmongTheOthers() throws {
        let workspace = try makeWorkspace()
        guard let location = workspace.location(containing: drive), let root = workspace.root(for: location) else { return XCTFail("no iCloud Drive") }
        XCTAssertEqual(location.name, "iCloud Drive")
        XCTAssertEqual(root.loadedChildren().map(\.name), ["Desktop", "Obsidian", "Papers", "Shortcut"])
        XCTAssertEqual(root.loadedChildren().filter(\.isLinked).map(\.name), ["Desktop", "Obsidian"])

        XCTAssertEqual(workspace.location(containing: plan)?.id, location.id)
        XCTAssertEqual(workspace.nodes(to: plan)?.nodes.map(\.name), ["com~apple~CloudDocs", "Desktop", "Trip", "Plan"])
        // Temporary folders come back as /private/var as well as /var.
        XCTAssertEqual(workspace.node(for: plan)?.url.resolvingSymlinksInPath().path, plan.resolvingSymlinksInPath().path)
        XCTAssertEqual(workspace.folderName(desktop), "Desktop")
        XCTAssertEqual(workspace.folderName(drive), "iCloud Drive")
        XCTAssertTrue(workspace.isLinkedFolder(desktop))
        XCTAssertFalse(workspace.isLinkedFolder(desktop.appendingPathComponent("Trip")))
    }

    func testLinkedFoldersStayPut() throws {
        let workspace = try makeWorkspace()
        XCTAssertNil(workspace.rename(desktop, to: "Renamed"))
        workspace.trash(desktop)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.path))
    }

    func testOpeningAFolderAddsItOnlyWhenNoLocationHasIt() throws {
        let workspace = try makeWorkspace()
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive"])

        let trip = desktop.appendingPathComponent("Trip")
        workspace.openFolder(trip)
        workspace.openFolder(drive)
        XCTAssertEqual(workspace.locations.count, 2, "already in iCloud Drive")
        XCTAssertEqual(workspace.selectedFolder?.path, drive.path)

        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere)
        workspace.openFolder(elsewhere)
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive", "Elsewhere"])
    }

    func testOnlyFoldersTheSidebarDoesntShowAreAddedByDropping() throws {
        let workspace = try makeWorkspace()
        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere)
        let file = base.appendingPathComponent("Loose.md")
        try "# Loose\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(workspace.newLocations(in: [elsewhere])?.map(\.path), [elsewhere.path])
        XCTAssertNil(workspace.newLocations(in: [elsewhere, file]), "a file can't be a location")
        XCTAssertNil(workspace.newLocations(in: [drive.appendingPathComponent("Papers")]), "already in iCloud Drive")
        XCTAssertNil(workspace.newLocations(in: [desktop]), "already in iCloud Drive, linked")
        XCTAssertNil(workspace.newLocations(in: []))

        XCTAssertTrue(workspace.addLocations([elsewhere]))
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive", "Elsewhere"])
        XCTAssertFalse(workspace.addLocations([elsewhere]), "there already")
        XCTAssertEqual(workspace.locations.count, 3)
    }

    func testSidebarAddsAFolderDroppedBetweenItsSections() throws {
        let workspace = try makeWorkspace()
        let sidebar = SidebarController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        sidebar.scrollView.frame = window.contentView!.bounds
        window.contentView!.addSubview(sidebar.scrollView)
        window.layoutIfNeeded()
        let outline = sidebar.outline
        XCTAssertEqual(outline.numberOfRows, 6, "two sections, iCloud Drive's open")

        let elsewhere = base.appendingPathComponent("Elsewhere")
        try make(elsewhere)
        let below = NSPoint(x: 100, y: 20)
        let papers = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FileNode }.first { $0.name == "Papers" }!
        let onPapers = outline.convert(NSPoint(x: 100, y: outline.rect(ofRow: outline.row(forItem: papers)).midY), to: nil)
        func validate(_ urls: [URL], at point: NSPoint, proposing item: Any?, _ index: Int) -> NSDragOperation {
            sidebar.outlineView(outline, validateDrop: FakeDrag(urls, at: point), proposedItem: item, proposedChildIndex: index)
        }

        XCTAssertEqual(validate([elsewhere], at: onPapers, proposing: papers, NSOutlineViewDropOnItemIndex), .copy, "into Papers, as before")
        XCTAssertEqual(validate([elsewhere], at: below, proposing: nil, 1), .link)
        XCTAssertEqual(validate([elsewhere], at: below, proposing: papers, 0), .link, "below the last row")
        let file = base.appendingPathComponent("Loose.md")
        try "# Loose\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(validate([file], at: below, proposing: nil, 1), [], "a file isn't a location")
        XCTAssertEqual(validate([desktop.appendingPathComponent("Trip")], at: below, proposing: nil, 1), [], "already there")

        XCTAssertTrue(sidebar.outlineView(outline, acceptDrop: FakeDrag([elsewhere], at: below), item: nil, childIndex: NSOutlineViewDropOnItemIndex))
        XCTAssertEqual(workspace.locations.map(\.name), ["Library", "iCloud Drive", "Elsewhere"])
        XCTAssertTrue((0..<outline.numberOfRows).contains { (outline.item(atRow: $0) as? SidebarEntry)?.sectionKey == workspace.locations.last?.id.uuidString })
    }

    func testSearchAndMoveToReachLinkedFolders() async throws {
        let workspace = try makeWorkspace()
        for _ in 0..<100 where workspace.index.isBuilding || workspace.index.entry(for: plan) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(workspace.index.entry(for: plan)?.place, "iCloud Drive › Desktop › Trip")
        XCTAssertFalse(workspace.index.entries.contains { $0.url.path == drive.appendingPathComponent("Desktop").path },
                       "the hidden link isn't a file of its own")
        let targets = workspace.moveTargets(for: plan).first { $0.location.isICloudDrive }?.folders
        XCTAssertEqual(targets?.map(\.name), ["iCloud Drive", "Desktop", "Trip", "Obsidian", "Vault", "Papers"])
        XCTAssertEqual(targets?.map(\.depth), [-1, 0, 1, 0, 1, 0])
    }
}

/// A drag of files from the Finder, held over the sidebar at a point in the window.
@MainActor
private final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("notebook-test-\(UUID().uuidString)"))
    let draggingLocation: NSPoint

    init(_ urls: [URL], at point: NSPoint) {
        draggingLocation = point
        draggingPasteboard.clearContents()
        draggingPasteboard.writeObjects(urls as [NSURL])
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
