import AppKit

/// A folder Folio shows in the sidebar: iCloud Drive or any folder you add. In the sandboxed build the app can only
/// reach it through the security-scoped bookmark made when you picked it.
public struct Location: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?

    /// Standardized, as every address in the app is, so "/private/tmp" and "/tmp" compare equal.
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }

    public var isICloudDrive: Bool { path == Location.iCloudDrivePath }

    /// Where iCloud Drive is, worked out from the real home folder (the sandbox gives the app another one).
    public static var iCloudDrivePath: String {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return home + "/Library/Mobile Documents/com~apple~CloudDocs"
    }
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
