import XCTest
@testable import FolioKit

/// iCloud Drive as the Finder shows it: with Desktop, Documents and the folders of apps that share theirs, which all
/// live outside iCloud Drive's own folder. Built here as a stand-in, next to a library folder for the other location.
@MainActor
final class LocationTests: XCTestCase {
    private var base: URL!
    private var drive: URL!
    private var desktop: URL { base.appendingPathComponent("Desktop") }
    private var plan: URL { desktop.appendingPathComponent("Trip/Plan.md") }

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("folio-icloud-\(UUID().uuidString)").standardizedFileURL
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
        UserDefaults.standard.set(drive.path, forKey: "FolioICloudDrive")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "FolioICloudDrive")
        UserDefaults.standard.removeObject(forKey: "FolioLibrary")
        try? FileManager.default.removeItem(at: base)
    }

    private func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A workspace with a library folder (for this run only), then iCloud Drive opened as File › Open does.
    private func makeWorkspace() throws -> Workspace {
        let library = base.appendingPathComponent("Library")
        try make(library)
        UserDefaults.standard.set(library.path, forKey: "FolioLibrary")
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
