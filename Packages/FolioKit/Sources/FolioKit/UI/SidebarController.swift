import AppKit
import SwiftUI

/// A row in the sidebar that isn't a file in a tree: a section title, a favourite, a recent note.
final class SidebarEntry: NSObject {
    enum Kind {
        case header(String, location: UUID?)
        case favorite(URL)
        case recent(URL)
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    var url: URL? {
        switch kind {
        case .favorite(let url), .recent(let url): url
        case .header: nil
        }
    }
}

/// The sidebar: favourites, recent notes and a tree for every location. An outline view, so arrow keys, type-to-select,
/// drag and drop and renaming in place work as in the Finder.
@MainActor
final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
    let workspace: Workspace
    let outline = SidebarOutlineView()
    let scrollView = NSScrollView()
    private var topItems: [AnyObject] = []
    private var isSelectingProgrammatically = false
    private var renaming: URL?

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowHeight = Theme.rowHeight
        outline.indentationPerLevel = 14
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.selectionHighlightStyle = .regular
        outline.focusRingType = .none
        outline.allowsEmptySelection = true
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.controller = self
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)
        outline.setAccessibilityLabel("Files")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scrollView.documentView = outline
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        workspace.sidebar = self
        rebuildTop()
        outline.reloadData()
        expandDefaults()
    }

    // MARK: - Items

    private func rebuildTop() {
        var items: [AnyObject] = []
        let favorites = workspace.favoriteURLs
        if !favorites.isEmpty {
            items.append(SidebarEntry(.header("Favorites", location: nil)))
            items.append(contentsOf: favorites.map { SidebarEntry(.favorite($0)) })
        }
        let recents = workspace.recentURLs
        if !recents.isEmpty {
            items.append(SidebarEntry(.header("Recent", location: nil)))
            items.append(contentsOf: recents.map { SidebarEntry(.recent($0)) })
        }
        for location in workspace.locations {
            items.append(SidebarEntry(.header(location.name, location: location.id)))
            if let root = workspace.root(for: location) { items.append(contentsOf: root.loadedChildren()) }
        }
        topItems = items
    }

    func reloadAll() {
        let expanded = expandedPaths()
        rebuildTop()
        outline.reloadData()
        restoreExpansion(expanded)
        selectCurrent()
    }

    /// Favourites and recents changed (or a location's top level): rebuild the top without closing folders.
    func reloadSections() {
        let expanded = expandedPaths()
        rebuildTop()
        outline.reloadData()
        restoreExpansion(expanded)
        selectCurrent()
    }

    /// Folders whose contents changed.
    func reload(_ nodes: [FileNode]) {
        let expanded = expandedPaths()
        var topChanged = false
        for node in nodes {
            if node.parent == nil {
                topChanged = true
            } else if outline.row(forItem: node) >= 0 {
                outline.reloadItem(node, reloadChildren: true)
            }
        }
        if topChanged {
            rebuildTop()
            outline.reloadData()
        }
        restoreExpansion(expanded)
        selectCurrent()
    }

    private func expandedPaths() -> Set<String> {
        var paths = Set<String>()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) { paths.insert(node.url.path) }
        }
        return paths
    }

    private func restoreExpansion(_ paths: Set<String>) {
        var row = 0
        while row < outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, paths.contains(node.url.path), !outline.isItemExpanded(node) {
                outline.expandItem(node)
            }
            row += 1
        }
    }

    private func expandDefaults() {
        let saved = Set(UserDefaults.standard.stringArray(forKey: "expandedFolders") ?? [])
        restoreExpansion(saved)
    }

    private func saveExpansion() {
        UserDefaults.standard.set(Array(expandedPaths()), forKey: "expandedFolders")
    }

    /// Opens the folders down to a file and scrolls it into view.
    func reveal(_ url: URL, select: Bool) {
        guard let location = workspace.location(containing: url), let root = workspace.root(for: location) else { return }
        var node = root
        let components = url.standardizedFileURL.path.dropFirst(location.url.path.count).split(separator: "/")
        for (index, component) in components.enumerated() {
            guard let next = node.child(named: String(component)) else { break }
            if index < components.count - 1 {
                if outline.row(forItem: next) >= 0 { outline.expandItem(next) }
            }
            node = next
        }
        if select { selectRow(for: node) }
    }

    private func selectCurrent() {
        guard let current = workspace.currentURL, let node = workspace.node(for: current) else { return }
        selectRow(for: node)
    }

    private func selectRow(for node: FileNode) {
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        isSelectingProgrammatically = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        isSelectingProgrammatically = false
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return topItems.count }
        return (item as? FileNode)?.loadedChildren().count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return topItems[index] }
        return (item as! FileNode).loadedChildren()[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isFolder ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let entry = item as? SidebarEntry, case .header = entry.kind { return 34 }
        return Theme.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        if let entry = item as? SidebarEntry, case .header = entry.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let entry = item as? SidebarEntry, case .header(let title, _) = entry.kind {
            let cell = outlineView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: nil) as? SidebarHeaderCell ?? SidebarHeaderCell()
            cell.label.stringValue = title
            return cell
        }
        let cell = outlineView.makeView(withIdentifier: SidebarFileCell.identifier, owner: nil) as? SidebarFileCell ?? SidebarFileCell()
        cell.label.delegate = self
        if let node = item as? FileNode {
            cell.configure(name: node.name, kind: node.kind, inCloud: node.isInCloud, url: node.url)
        } else if let entry = item as? SidebarEntry, let url = entry.url {
            let kind = FileKind(url: url, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
            let name = kind == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            cell.configure(name: name, kind: kind, inCloud: false, url: url, symbol: { if case .favorite = entry.kind, kind == .folder { return "star" } else { return nil } }())
        }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) { saveExpansion() }
    func outlineViewItemDidCollapse(_ notification: Notification) { saveExpansion() }

    // MARK: - Selection and clicks

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically, renaming == nil else { return }
        let row = outline.selectedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if let node = item as? FileNode {
            if node.isFolder {
                workspace.selectedFolder = node.url
            } else {
                workspace.open(node.url)
            }
        } else if let entry = item as? SidebarEntry, let url = entry.url {
            workspace.open(url)
        }
    }

    @objc private func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, node.isFolder else { return }
        // A click on a folder's name opens or closes it, as in Notion.
        if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown {
            let point = outline.convert(event.locationInWindow, from: nil)
            let cellFrame = outline.frameOfCell(atColumn: 0, row: row)
            guard point.x >= cellFrame.minX else { return }
        }
        if outline.isItemExpanded(node) { outline.animator().collapseItem(node) } else { outline.animator().expandItem(node) }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode, !node.isFolder, node.kind != .note else { return }
        workspace.quickLook(node.url)
    }

    func url(at row: Int) -> URL? {
        guard row >= 0 else { return nil }
        let item = outline.item(atRow: row)
        return (item as? FileNode)?.url ?? (item as? SidebarEntry)?.url
    }

    var selectedURL: URL? { url(at: outline.selectedRow) }

    // MARK: - Renaming in place

    func beginRenaming(_ url: URL) {
        guard let node = workspace.node(for: url) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFileCell else { return }
        renaming = url
        cell.label.isEditable = true
        cell.label.isSelectable = true
        outline.window?.makeFirstResponder(cell.label)
        if let editor = cell.label.currentEditor() { editor.selectedRange = NSRange(location: 0, length: (cell.label.stringValue as NSString).length) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let url = renaming else { return }
        renaming = nil
        field.isEditable = false
        field.isSelectable = false
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        if movement == NSTextMovement.cancel.rawValue || name.isEmpty || name == current {
            field.stringValue = current
        } else {
            var target = name
            // Typing a name with the extension for a file that has one keeps just one extension.
            if !url.pathExtension.isEmpty, (name as NSString).pathExtension.lowercased() == url.pathExtension.lowercased() {
                target = (name as NSString).deletingPathExtension
            }
            if workspace.rename(url, to: target) == nil { field.stringValue = current }
        }
        outline.window?.makeFirstResponder(outline)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField, let url = renaming {
            field.stringValue = FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
            outline.window?.makeFirstResponder(outline)
            return true
        }
        return false
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        let item = row >= 0 ? outline.item(atRow: row) : nil
        if let entry = item as? SidebarEntry, case .header(_, let locationID) = entry.kind, let locationID,
           let location = workspace.locations.first(where: { $0.id == locationID }) {
            add(menu, "New Note", "square.and.pencil") { [weak self] in self?.workspace.newNote(in: location.url) }
            add(menu, "New Folder", "folder.badge.plus") { [weak self] in self?.workspace.newFolder(in: location.url) }
            menu.addItem(.separator())
            add(menu, "Show in Finder", "folder") { [weak self] in self?.workspace.revealInFinder(location.url) }
            add(menu, "Remove from Sidebar", "minus.circle") { [weak self] in self?.workspace.removeLocation(locationID) }
            return
        }
        guard let url = url(at: row) else { return }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        let folder = isFolder ? url : url.deletingLastPathComponent()
        add(menu, "New Note in “\(folder.lastPathComponent)”", "square.and.pencil") { [weak self] in self?.workspace.newNote(in: folder) }
        add(menu, "New Folder", "folder.badge.plus") { [weak self] in self?.workspace.newFolder(in: folder) }
        menu.addItem(.separator())
        if !isFolder, FileKind(url: url, isDirectory: false) != .note {
            add(menu, "Quick Look", "eye") { [weak self] in self?.workspace.quickLook(url) }
        }
        add(menu, "Rename", "pencil") { [weak self] in self?.beginRenaming(url) }
        add(menu, "Move to…", "folder") { [weak self] in
            self?.workspace.paletteMode = .move(url)
            self?.workspace.isPaletteOpen = true
        }
        add(menu, "Duplicate", "plus.square.on.square") { [weak self] in self?.workspace.duplicate(url) }
        let favorite = workspace.isFavorite(url)
        add(menu, favorite ? "Remove from Favorites" : "Add to Favorites", favorite ? "star.slash" : "star") { [weak self] in self?.workspace.toggleFavorite(url) }
        menu.addItem(.separator())
        if !isFolder { add(menu, "Copy Link", "link") { [weak self] in self?.workspace.copyLink(url) } }
        add(menu, "Show in Finder", "folder") { [weak self] in self?.workspace.revealInFinder(url) }
        menu.addItem(.separator())
        add(menu, "Move to Trash", "trash") { [weak self] in self?.workspace.trash(url) }
    }

    private func add(_ menu: NSMenu, _ title: String, _ symbol: String, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, action: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if let node = item as? FileNode { return node.url as NSURL }
        if let entry = item as? SidebarEntry, let url = entry.url { return url as NSURL }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let folder = dropFolder(for: item) else { return [] }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, !urls.contains(where: { folder.path == $0.path || folder.path.hasPrefix($0.path + "/") }) else { return [] }
        if let node = folderNode(for: item) { outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        let local = urls.allSatisfy { workspace.location(containing: $0) != nil }
        return local && !NSEvent.modifierFlags.contains(.option) ? .move : .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let folder = dropFolder(for: item) else { return false }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let copy = NSEvent.modifierFlags.contains(.option)
        for url in urls {
            if workspace.location(containing: url) != nil, !copy {
                if url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL { workspace.move(url, into: folder) }
            } else {
                let destination = FileOperations.uniqueURL(in: folder, name: url.deletingPathExtension().lastPathComponent, extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }
        workspace.refreshNow(folder)
        return true
    }

    private func folderNode(for item: Any?) -> FileNode? {
        guard let node = item as? FileNode else { return nil }
        return node.isFolder ? node : node.parent
    }

    private func dropFolder(for item: Any?) -> URL? {
        if let node = folderNode(for: item) { return node.url }
        if let node = item as? FileNode, node.parent == nil { return node.url.deletingLastPathComponent() }
        if let file = item as? FileNode { return file.url.deletingLastPathComponent() }
        return nil
    }
}

/// Keys the Finder has: Return renames, ⌘⌫ moves to the Trash, Space shows Quick Look.
final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarController?

    override func keyDown(with event: NSEvent) {
        guard let controller, let url = controller.selectedURL else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (event.keyCode, flags) {
        case (36, []), (76, []):
            controller.beginRenaming(url)
        case (51, .command):
            controller.workspace.trash(url)
        case (49, []):
            if FileKind(url: url, isDirectory: false) == .note { super.keyDown(with: event) } else { controller.workspace.quickLook(url) }
        default:
            super.keyDown(with: event)
        }
    }

    // No focus ring or blue highlight: rows draw their own selection.
    override var allowsVibrancy: Bool { false }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += 2
        return frame
    }
}

final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 1)
        Theme.selected.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

final class SidebarHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("header")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Theme.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class SidebarFileCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("file")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let accessory = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = label
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        accessory.contentTintColor = Theme.textTertiary
        addSubview(icon)
        addSubview(label)
        addSubview(accessory)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -4),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, kind: FileKind, inCloud: Bool, url: URL, symbol: String? = nil) {
        label.stringValue = name
        label.textColor = inCloud ? Theme.textSecondary : Theme.text
        icon.image = NSImage(systemSymbolName: symbol ?? kind.symbol, accessibilityDescription: nil)
        icon.contentTintColor = kind.tint
        accessory.image = inCloud ? NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: "In iCloud, not downloaded") : nil
        toolTip = url.path
        setAccessibilityLabel(name)
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The sidebar in SwiftUI.
struct SidebarOutline: NSViewRepresentable {
    let workspace: Workspace

    func makeCoordinator() -> SidebarController { SidebarController(workspace: workspace) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}
