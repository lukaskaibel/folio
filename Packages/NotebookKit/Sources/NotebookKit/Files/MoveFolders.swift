import Foundation

/// Every folder of every location, in the order Move To lists them: under each location its own folders and the linked
/// ones, by their places, with how deep each is. Made in the background (`Workspace.prepareMoveFolders`).
struct MoveFolders: Sendable {
    /// What the list was made from; another one means it is out of date.
    struct Key: Equatable, Sendable {
        var folders: Int
        var locations: [Location]
        var hidden: [String]
    }

    struct Folder: Sendable {
        var url: URL
        var name: String
        /// -1 for the location itself, 0 for the folders at its top level.
        var depth: Int
        var path: String
    }

    let key: Key
    let targets: [(location: Location, folders: [Folder])]

    /// `folders` are all the folders the index has; the hidden ones stay out.
    init(_ key: Key, folders: [(url: URL, name: String, path: String)]) {
        self.key = key
        let shown = folders.filter { !SearchIndex.isHidden($0.path, in: key.hidden) }
        targets = key.locations.map { location in
            // Linked folders (iCloud Drive's Desktop) sit at the top, under their own names.
            let inside = location.folders.flatMap { folder -> [(folder: Folder, place: String)] in
                let base = folder.url.path
                let prefix = folder.linked.map { $0.name + "/" } ?? ""
                var found = shown.compactMap { entry -> (folder: Folder, place: String)? in
                    guard entry.path.hasPrefix(base + "/") else { return nil }
                    let relative = prefix + String(entry.path.dropFirst(base.count + 1))
                    return (Folder(url: entry.url, name: entry.name, depth: relative.split(separator: "/").count - 1, path: entry.path), relative)
                }
                if let linked = folder.linked, !SearchIndex.isHidden(linked.url.path, in: key.hidden) {
                    found.append((Folder(url: linked.url, name: linked.name, depth: 0, path: linked.url.standardizedFileURL.path), linked.name))
                }
                return found
            }
            .sorted { $0.place.localizedStandardCompare($1.place) == .orderedAscending }
            .map(\.folder)
            return (location, [Folder(url: location.url, name: location.name, depth: -1, path: location.url.path)] + inside)
        }
    }
}
