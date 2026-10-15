import AppKit

/// A folder Folio shows in the sidebar: iCloud Drive or any folder you add. In the sandboxed build the app can only
/// reach it through the security-scoped bookmark made when you picked it.
public struct Location: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    /// Folders shown in the location that are somewhere else on disk, looked up again every launch.
    public var linked: [LinkedFolder] = []

    private enum CodingKeys: String, CodingKey { case id, name, path, bookmark }

    public init(id: UUID, name: String, path: String, bookmark: Data?) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }

    /// Standardized, as every address in the app is, so "/private/tmp" and "/tmp" compare equal.
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }

    public var isICloudDrive: Bool { path == Location.iCloudDrivePath }

    /// Where iCloud Drive is, worked out from the real home folder (the sandbox gives the app another one).
    public static var iCloudDrivePath: String {
        #if DEBUG
        // A stand-in iCloud Drive, for tests.
        if let path = UserDefaults.standard.string(forKey: "FolioICloudDrive") {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        }
        #endif
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Mobile Documents/com~apple~CloudDocs"
    }

    /// The folder a file is under in this location, the location's own or a linked one, with the place the sidebar
    /// gives it ("iCloud Drive › Desktop").
    func folder(containing path: String) -> (url: URL, place: String, linked: LinkedFolder?)? {
        folders.first { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }

    /// The location's own folder, then the linked ones.
    var folders: [(url: URL, place: String, linked: LinkedFolder?)] {
        [(url, name, nil)] + linked.map { ($0.url, name + " › " + $0.name, $0) }
    }

    func contains(_ url: URL) -> Bool {
        folder(containing: url.standardizedFileURL.path) != nil
    }

    func isLinkedFolder(_ url: URL) -> Bool {
        linked.contains { $0.url.path == url.standardizedFileURL.path }
    }

    /// Looks up the linked folders again: iCloud Drive's, for now.
    mutating func findLinkedFolders() {
        linked = isICloudDrive ? Self.iCloudDriveLinks(in: url) : []
    }

    /// What the Finder shows in iCloud Drive without it being in iCloud Drive's folder: Desktop and Documents when
    /// they are kept in iCloud (hidden links to the real folders), and the iCloud folders of apps that share theirs,
    /// such as Pages or Obsidian. Those sit next to iCloud Drive, and the system hides the ones of every other app.
    static func iCloudDriveLinks(in drive: URL) -> [LinkedFolder] {
        let files = FileManager.default
        var found: [LinkedFolder] = []
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isHiddenKey]
        for item in (try? files.contentsOfDirectory(at: drive, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard let values = try? item.resourceValues(forKeys: keys), values.isSymbolicLink == true, values.isHidden == true else { continue }
            let target = item.resolvingSymlinksInPath().standardizedFileURL
            if isReadableFolder(target) { found.append(LinkedFolder(name: item.lastPathComponent, url: target)) }
        }
        let containers = drive.deletingLastPathComponent()
        for container in (try? files.contentsOfDirectory(at: containers, includingPropertiesForKeys: [.isHiddenKey, .localizedNameKey])) ?? [] {
            let values = try? container.resourceValues(forKeys: [.isHiddenKey, .localizedNameKey])
            guard container.standardizedFileURL.path != drive.path, values?.isHidden == false else { continue }
            let documents = container.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
            guard isReadableFolder(documents) else { continue }
            var name = values?.localizedName ?? container.lastPathComponent
            if name == container.lastPathComponent {
                // Without a name from iCloud, the app's from the container's: "iCloud~md~obsidian" is Obsidian.
                let last = container.lastPathComponent.split(separator: "~").last.map(String.init) ?? name
                name = last.prefix(1).uppercased() + last.dropFirst()
            }
            found.append(LinkedFolder(name: name, url: documents))
        }
        return found
    }

    /// In the sandboxed build iCloud Drive's bookmark doesn't reach these, and folders the app can't read stay out.
    private static func isReadableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }
}

/// A folder that shows inside a location without being in its folder, such as iCloud Drive's Desktop.
public struct LinkedFolder: Equatable, Sendable {
    public var name: String
    public var url: URL
}

/// The locations, kept in the app's settings, with their bookmarks.
@MainActor
enum LocationStore {
    private static let key = "locations"
    private static var accessing: Set<String> = []

    static func load() -> [Location] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var locations = try? JSONDecoder().decode([Location].self, from: data) else { return [] }
        for index in locations.indices {
            if let bookmark = locations[index].bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                    locations[index].path = url.standardizedFileURL.path
                    startAccessing(url)
                    if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        locations[index].bookmark = fresh
                    }
                }
            }
        }
        return locations
    }

    static func save(_ locations: [Location]) {
        if let data = try? JSONEncoder().encode(locations) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func make(for url: URL) -> Location {
        startAccessing(url)
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = url.path == Location.iCloudDrivePath ? "iCloud Drive" : FileManager.default.displayName(atPath: url.path)
        return Location(id: UUID(), name: name, path: url.standardizedFileURL.path, bookmark: bookmark)
    }

    static func startAccessing(_ url: URL) {
        guard !accessing.contains(url.path) else { return }
        if url.startAccessingSecurityScopedResource() { accessing.insert(url.path) }
    }

    /// Asks for a folder, starting in iCloud Drive or wherever `directory` says.
    static func choose(startingIn directory: URL? = nil, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Open"
        panel.message = message ?? "Choose a folder with your notes. Folio shows everything in it."
        panel.directoryURL = directory ?? URL(fileURLWithPath: Location.iCloudDrivePath, isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}
