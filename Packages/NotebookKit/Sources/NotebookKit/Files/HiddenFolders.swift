import CryptoKit
import Foundation

/// The folders you hid from the sidebar. They are kept in iCloud's key-value store, which takes them to your other
/// devices, and in the app's settings, which is all a build without the iCloud entitlement has.
///
/// A folder goes by its place in iCloud ("com~apple~CloudDocs/Archive"), which is the same on a Mac, an iPhone and an
/// iPad, and by its path when it isn't in iCloud.
@MainActor
@Observable
final class HiddenFolders {
    /// Every folder hidden, by the names `key(for:links:)` gives them.
    private(set) var keys: Set<String>
    /// The locations showing their hidden folders for now. Not kept: next time they are hidden again.
    private(set) var shownIn: Set<UUID> = []
    /// Another device hid or showed a folder.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let defaultsKey = "hiddenFolders"
    private static let uploadedKey = "hiddenFoldersInICloud"
    private static let cloudPrefix = "hiddenFolder."

    /// With no defaults and no cloud the folders are kept for this run only (tests, the sample notes).
    init(defaults: UserDefaults? = .standard, cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        // Without the entitlement the store keeps nothing, and says so here.
        self.cloud = cloud?.synchronize() == true ? cloud : nil
        keys = Set(defaults?.stringArray(forKey: Self.defaultsKey) ?? [])
        guard let cloud = self.cloud else { return }
        // Folders hidden before iCloud was there go up once; from then on iCloud has the last word.
        if defaults?.bool(forKey: Self.uploadedKey) != true {
            for key in keys { cloud.set(key, forKey: Self.cloudKey(key)) }
            defaults?.set(true, forKey: Self.uploadedKey)
        }
        keys = Self.read(cloud)
        save()
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let cloud = self.cloud else { return }
                let fresh = Self.read(cloud)
                guard fresh != self.keys else { return }
                self.keys = fresh
                self.save()
                self.onChange?()
            }
        }
    }

    func set(_ key: String, hidden: Bool) {
        guard keys.contains(key) != hidden else { return }
        if hidden {
            keys.insert(key)
            cloud?.set(key, forKey: Self.cloudKey(key))
        } else {
            keys.remove(key)
            cloud?.removeObject(forKey: Self.cloudKey(key))
        }
        save()
    }

    func show(_ shows: Bool, in location: UUID) {
        if shows { shownIn.insert(location) } else { shownIn.remove(location) }
    }

    /// A folder renamed or moved in Notebook stays hidden, and so do the folders hidden inside it.
    func move(_ old: String, to new: String) {
        for key in keys where key == old || key.hasPrefix(old + "/") {
            set(key, hidden: false)
            set(new + key.dropFirst(old.count), hidden: true)
        }
    }

    /// A folder thrown away takes its hidden folders with it, so a new one of the same name isn't hidden.
    func forget(_ old: String) {
        for key in keys where key == old || key.hasPrefix(old + "/") { set(key, hidden: false) }
    }

    private func save() {
        defaults?.set(keys.sorted(), forKey: Self.defaultsKey)
    }

    /// One entry per folder, so folders hidden on two devices at the same time both stay hidden. The store's keys
    /// can have 64 bytes, too few for a path, so the path is the value.
    static func cloudKey(_ key: String) -> String {
        cloudPrefix + SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ cloud: NSUbiquitousKeyValueStore) -> Set<String> {
        Set(cloud.dictionaryRepresentation.compactMap { $0.key.hasPrefix(cloudPrefix) ? $0.value as? String : nil })
    }

    /// The name a folder is kept under: its place in iCloud, through iCloud Drive's links (a Mac keeps Desktop in
    /// ~/Desktop, an iPhone in iCloud Drive), or its path.
    static func key(for url: URL, links: [LinkedFolder]) -> String {
        var path = withoutPrivate(url.standardizedFileURL.path)
        if let link = links.first(where: { path == withoutPrivate($0.url.path) || path.hasPrefix(withoutPrivate($0.url.path) + "/") }) {
            path = withoutPrivate(link.alias.path) + path.dropFirst(withoutPrivate(link.url.path).count)
        }
        if let range = path.range(of: "/Mobile Documents/") { return String(path[range.upperBound...]) }
        return path
    }

    /// "/private/tmp/Notes" and "/tmp/Notes" are one folder, and file events give the first where the app has the second.
    nonisolated static func withoutPrivate(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
