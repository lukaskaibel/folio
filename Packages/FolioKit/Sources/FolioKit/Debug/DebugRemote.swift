#if DEBUG
import AppKit
import SwiftUI

/// Development-only remote control, as in Issues. Launch with `-debugCommandFile <path>` and append lines to that
/// file to drive the app with real mouse and keyboard events (click, drag, type, keys) and take snapshots, so the
/// app can be tested end to end without a person at the keyboard. Results go to `<path>.log`.
@MainActor
enum DebugRemote {
    private static var processed = 0
    private static var timer: Timer?
    private static var activity: NSObjectProtocol?
    private static weak var workspace: Workspace?

    static func startIfRequested(workspace: Workspace) {
        guard let path = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        self.workspace = workspace
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Debug remote")
        processed = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
        if processed > 0 { processed -= 1 }
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated { poll(path) }
        }
        // In every run loop mode, so commands keep coming while a popover, menu or drag is in progress.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static var waitUntil: Date?

    private static func poll(_ path: String) {
        if let waitUntil, Date() < waitUntil { return }
        waitUntil = nil
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        // The last element is what follows the final newline: not a finished command yet.
        while processed < lines.count - 1 {
            let line = lines[processed]
            processed += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            run(line)
            if waitUntil != nil { return }
        }
    }

    static func log(_ text: String) {
        guard let path = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        let url = URL(fileURLWithPath: path + ".log")
        let line = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Commands go to the main window, or after `usewindow file` to the last file window opened.
    private static var usesFileWindow = false

    private static var window: NSWindow? {
        if usesFileWindow { return FileWindows.shared.windows.last }
        return NSApp.windows.first { $0.isVisible && $0.frame.width > 500 && !($0 is NSPanel) && !($0.windowController is FileWindowController) }
    }

    private static var editor: EditorController? {
        if usesFileWindow { return (FileWindows.shared.windows.last?.windowController as? FileWindowController)?.editor }
        return workspace?.editor
    }

    private static func run(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        switch command {
        case "wait":
            waitUntil = Date().addingTimeInterval(numbers.first ?? 0.5)
        case "open":
            guard let workspace, let location = workspace.locations.first else { return }
            let url = argument.hasPrefix("/") ? URL(fileURLWithPath: argument) : location.url.appendingPathComponent(argument)
            workspace.open(url)
        case "activate":
            window?.orderFront(nil)
        case "focus":
            if let editor { window?.makeFirstResponder(editor.textView) }
        case "caret":
            if let editor, let location = numbers.first {
                window?.makeFirstResponder(editor.textView)
                editor.textView.setSelectedRange(NSRange(location: Int(location), length: 0))
            }
        case "select":
            if let editor, numbers.count == 2 {
                window?.makeFirstResponder(editor.textView)
                editor.textView.setSelectedRange(NSRange(location: Int(numbers[0]), length: Int(numbers[1])))
            }
        case "type":
            for character in argument.replacingOccurrences(of: "\\n", with: "\n") {
                if character == "\n" { sendKey("\r", code: 36) } else { sendKey(String(character), code: 0) }
            }
        case "key":
            key(argument)
        case "click", "doubleclick", "rightclick":
            // click <x> <y>: in points from the window's top-left corner.
            if numbers.count >= 2 { click(at: CGPoint(x: numbers[0], y: numbers[1]), count: command == "doubleclick" ? 2 : 1, right: command == "rightclick") }
        case "clicktext":
            // clicktext <character index> [fraction across the character]
            if let editor, let index = numbers.first, let point = windowPoint(ofCharacter: Int(index), fraction: numbers.count > 1 ? numbers[1] : 0.5, in: editor) {
                click(at: point)
            }
        case "drag":
            // drag <from character> <to character>
            if let editor, numbers.count == 2,
               let from = windowPoint(ofCharacter: Int(numbers[0]), fraction: 0.05, in: editor),
               let to = windowPoint(ofCharacter: Int(numbers[1]), fraction: 0.95, in: editor) {
                click(at: from, dragTo: to)
            }
        case "selectrow":
            // selectrow <name>: selects that sidebar row as a click does, and gives the sidebar the focus.
            guard let outline = workspace?.sidebar?.outline else { return }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView, cell.textField?.stringValue == argument else { continue }
                window?.makeFirstResponder(outline)
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                log("selected row \(row) \(argument)")
                break
            }
        case "clickrow", "doubleclickrow":
            // clickrow <name>: the sidebar row showing that name.
            if let point = sidebarRowPoint(named: argument) { click(at: point, count: command == "doubleclickrow" ? 2 : 1) } else { log("no row \(argument)") }
        case "clickobject":
            // clickobject <character index> [x y]: inside the object drawn there, at x, y from its top-left.
            if let editor, let index = numbers.first, let window, let content = window.contentView,
               let rect = editor.layoutManager.rect(forObjectAt: Int(index), origin: editor.textView.textContainerOrigin) {
                let blockRect = blockObjectRect(editor, Int(index)) ?? rect
                let inText = NSPoint(x: blockRect.minX + (numbers.count > 2 ? numbers[1] : blockRect.width / 2), y: blockRect.minY + (numbers.count > 2 ? numbers[2] : blockRect.height / 2))
                let inWindow = editor.textView.convert(inText, to: nil)
                click(at: CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y), count: 1)
            } else {
                log("no object at \(argument)")
            }
        case "dragpoints":
            if numbers.count == 4 { click(at: CGPoint(x: numbers[0], y: numbers[1]), dragTo: CGPoint(x: numbers[2], y: numbers[3])) }
        case "scroll":
            if let editor, let y = numbers.first {
                editor.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
                editor.scrollView.reflectScrolledClipView(editor.scrollView.contentView)
            }
        case "hover":
            // hover <character index>: as if the pointer rested on that character (the real one stays put).
            if let editor, let index = numbers.first, let window, let content = window.contentView,
               let point = windowPoint(ofCharacter: Int(index), fraction: 0.5, in: editor) {
                editor.updateCopyButton(at: editor.textView.convert(NSPoint(x: point.x, y: content.bounds.height - point.y), from: nil))
                let button = editor.textView.copyButton
                let frame = editor.textView.convert(button.frame, to: nil)
                log(button.isHidden ? "hover \(Int(index)): no copy button" : "hover \(Int(index)): copy button at \(Int(frame.midX)) \(Int(content.bounds.height - frame.midY))")
            }
        case "snapshot":
            snapshot(to: argument)
        case "dump":
            dump()
        case "rect":
            // rect <character index>: where a character is drawn, in window points from the top-left.
            if let editor, let index = numbers.first, let point = windowPoint(ofCharacter: Int(index), fraction: 0.5, in: editor) {
                log("rect \(Int(index)): \(Int(point.x)) \(Int(point.y)) y-in-text=\(Int(editor.yPosition(of: Int(index)))) scroll=\(Int(editor.scrollView.contentView.bounds.minY))")
            }
        case "object":
            // object <index>: what is drawn at a character.
            if let editor, let index = numbers.first.map(Int.init) {
                let layout = editor.layoutManager
                let glyph = layout.glyphIndexForCharacter(at: index)
                let object = layout.object(at: index)
                let character = (editor.text as NSString).substring(with: NSRange(location: index, length: 1))
                log("object \(index) '\(character)': \(object.map { String(describing: $0.kind) } ?? "none") glyph=\(glyph) property=\(layout.propertyForGlyph(at: glyph).rawValue) rect=\(layout.rect(forObjectAt: index, origin: editor.textView.textContainerOrigin).map { "\($0)" } ?? "nil")")
            }
        case "views":
            // views <class name>: the views of that class in the window, with their frames.
            func walk(_ view: NSView, _ depth: Int) {
                if String(describing: type(of: view)).contains(argument) {
                    log("view \(type(of: view)) frame=\(view.convert(view.bounds, to: nil)) hidden=\(view.isHiddenOrHasHiddenAncestor) subviews=\(view.subviews.count)")
                }
                for subview in view.subviews { walk(subview, depth + 1) }
            }
            if let root = window?.contentView?.superview { walk(root, 0) }
        case "find":
            // find <text>: the character index where it first is.
            if let editor { log("find \"\(argument)\": \((editor.text as NSString).range(of: argument).location)") }
        case "appearance":
            NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "window":
            if numbers.count == 2, let window {
                var frame = window.frame
                frame.size = CGSize(width: numbers[0], height: numbers[1])
                window.setFrame(frame, display: true)
            }
        case "menu":
            // menu <Menu>/<Item>: runs a menu item as choosing it would.
            let path = argument.split(separator: "/").map(String.init)
            guard path.count == 2, let menu = NSApp.mainMenu?.item(withTitle: path[0])?.submenu else { log("no menu \(argument)"); return }
            // What happens before a menu opens, so SwiftUI brings its items up to date.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            menu.delegate?.menuDidClose?(menu)
            guard let index = menu.items.firstIndex(where: { $0.title == path[1] }) else { log("no item \(argument): \(menu.items.map(\.title))"); return }
            let item = menu.items[index]
            log("menu \(argument): enabled=\(item.isEnabled) key=\(item.keyEquivalentModifierMask.rawValue)+\(item.keyEquivalent)")
            if item.isEnabled { menu.performActionForItem(at: index) }
        case "menus":
            // menus: every menu item with its shortcut and action, to check shortcuts are unique.
            func walk(_ menu: NSMenu, _ path: String) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                for item in menu.items where !item.isSeparatorItem {
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue >> 16)+\(item.keyEquivalent)]"
                    log("\(path)/\(item.title)\(key) \(item.action.map(NSStringFromSelector) ?? "")\(item.isEnabled ? "" : " (disabled)")")
                    if let submenu = item.submenu { walk(submenu, "\(path)/\(item.title)") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
        case "editlink":
            // editlink <index>: opens the link editor for the link around a character, as its pencil does.
            if let editor, let index = numbers.first.map(Int.init) {
                let line = editor.document.lines[editor.document.lineIndex(containing: index)]
                if let link = line.spans.first(where: { if case .link = $0.kind { return $0.range.contains(index) } else { return false } }) {
                    log("editlink opening \(link.range)")
                    editor.editLink(at: link.range)
                    log("editlink opened")
                } else {
                    log("editlink: no link at \(index)")
                }
            }
        case "popovertype":
            // popovertype <text>: what typing the address into the open link editor does.
            if let model = LinkEditorModel.current { model.address = argument; log("popovertype ok") } else { log("popovertype: no link editor") }
        case "popoverreturn":
            if let model = LinkEditorModel.current { model.finish(.save(model.address)) }
        case "showcaret":
            MarkdownTextView.drawsCaretAlways = argument == "1"
            editor?.textView.needsDisplay = true
        case "settings":
            // settings <general|text|sidebar>: opens Settings at that tab.
            UserDefaults.standard.set(argument.isEmpty ? "general" : argument, forKey: "settingsTab")
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "usewindow":
            usesFileWindow = argument == "file"
        case "openfile":
            FileWindows.shared.open(URL(fileURLWithPath: argument))
        case "openurls":
            // openurls <path>: what File › Open and the Dock icon do with a file or folder.
            FileWindows.shared.open([URL(fileURLWithPath: argument)])
        case "rows":
            // rows: the sidebar as shown, indented, with the selected row marked and the visible rows' range.
            if let outline = workspace?.sidebar?.outline {
                let lines = (0..<outline.numberOfRows).map { row -> String in
                    let item = outline.item(atRow: row)
                    let name = (item as? FileNode)?.name ?? (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue ?? "?"
                    return String(repeating: "  ", count: outline.level(forRow: row)) + name + (outline.selectedRow == row ? " *" : "")
                }
                let visible = outline.rows(in: outline.visibleRect)
                log("rows (visible \(visible.location)..<\(visible.location + visible.length)):\n" + lines.joined(separator: "\n"))
            }
        case "exportto":
            // exportto <pdf|png> <path>: writes the open note without asking where.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            if let editor, bits.count == 2 {
                let title = usesFileWindow ? (window?.title ?? "") : (workspace?.currentTitle ?? "")
                Task { @MainActor in
                    let data = await NoteExporter.data(for: editor, title: title, as: bits[0] == "png" ? .png : .pdf)
                    try? data?.write(to: URL(fileURLWithPath: bits[1]))
                    log("exportto \(bits[0]): \(data?.count ?? 0) bytes")
                }
            }
        case "set":
            // set <setting> <value>: face, size, spacing, width, headings, onlynotes, dim, foldersfirst.
            let bits = argument.split(separator: " ").map(String.init)
            guard bits.count == 2 else { break }
            let settings = FolioSettings.shared
            switch bits[0] {
            case "face": if let face = Typography.Face(rawValue: bits[1]) { settings.typography.face = face }
            case "size": if let size = Double(bits[1]) { settings.typography.size = size }
            case "spacing": if let spacing = Typography.Spacing(rawValue: bits[1]) { settings.typography.spacing = spacing }
            case "width": if let width = Typography.Width(rawValue: bits[1]) { settings.typography.width = width }
            case "headings": if let marks = FolioSettings.HeadingMarks(rawValue: bits[1]) { settings.headingMarks = marks }
            case "onlynotes": settings.showsOnlyNotes = bits[1] == "1"
            case "dim": settings.dimsOtherFiles = bits[1] == "1"
            case "foldersfirst": settings.foldersFirst = bits[1] == "1"
            default: break
            }
            log("set \(argument)")
        case "palette":
            workspace?.search.focus()
        case "search":
            // search <text>: what the suggestions menu lists for it.
            if let search = workspace?.search {
                search.field.stringValue = argument
                let sections = search.sections(for: argument)
                log("search \(argument): " + sections.map { "[\($0.title ?? "")] " + $0.items.map { $0.title + ($0.secondaryTitle.map { " (\($0))" } ?? "") }.joined(separator: " | ") }.joined(separator: " "))
            }
        case "searchfield":
            // searchfield: where the search field, its buttons and the text you type in it are, in the field's points.
            guard let field = workspace?.search.field, let cell = field.cell as? NSSearchFieldCell else { break }
            let bounds = field.bounds
            var line = "searchfield frame=\(field.convert(bounds, to: nil)) bounds=\(bounds) focused=\(field.currentEditor() != nil)"
            line += " glass=\(cell.searchButtonRect(forBounds: bounds)) text=\(cell.searchTextRect(forBounds: bounds)) clear=\(cell.cancelButtonRect(forBounds: bounds))"
            if let editor = field.currentEditor() as? NSTextView, let layout = editor.layoutManager, let container = editor.textContainer {
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container).offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                line += " editor=\(editor.convert(editor.bounds, to: field)) typed=\(editor.convert(used, to: field))"
            }
            log(line)
        case "selectlist":
            // selectlist <row>: selects a row of the inspector's list, as a click on it does.
            if let root = window?.contentView?.superview, let row = numbers.first.map(Int.init) {
                func lists(in view: NSView) -> [NSOutlineView] {
                    (view as? NSOutlineView).map { [$0] } ?? view.subviews.flatMap(lists)
                }
                if let list = lists(in: root).first(where: { $0 !== workspace?.sidebar?.outline }) {
                    list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    log("selectlist \(row) of \(list.numberOfRows)")
                }
            }
        case "expanded":
            // expanded: the folders open in the sidebar.
            if let outline = workspace?.sidebar?.outline {
                let names = (0..<outline.numberOfRows).compactMap { row -> String? in
                    guard let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) else { return nil }
                    return node.name
                }
                log("expanded: " + names.joined(separator: ", "))
            }
        case "movetargets":
            // movetargets: the folders Move To lists for the open file.
            if let workspace, let url = workspace.currentURL {
                log("movetargets: " + workspace.moveTargets(for: url).map { target in
                    "[\(target.location.name)] " + target.folders.map { String(repeating: "·", count: max(0, $0.depth)) + $0.name }.joined(separator: ", ")
                }.joined(separator: " "))
            }
        case "searchpick":
            // searchpick <n>: chooses the nth suggestion, counted over all sections.
            if let search = workspace?.search, let n = numbers.first.map(Int.init) {
                let items = search.sections(for: search.field.stringValue).flatMap(\.items)
                if let item = items[safe: n] { search.run(item.representedValue) }
            }
        case "newnote":
            workspace?.newNote()
        case "swipe":
            // swipe back|forward <0…1>: holds a swipe still part of the way; swipe back|forward play: the whole
            // thing by itself; swipe end 1|0: goes to the page, or back to where it started.
            let bits = argument.split(separator: " ").map(String.init)
            guard let pages = workspace?.pages, let first = bits.first else { break }
            if first == "end" {
                pages.end(commit: bits.count > 1 && bits[1] == "1")
            } else {
                let direction: PageSwiper.Direction = first == "back" ? .back : .forward
                if bits.count > 1, bits[1] == "play" { pages.debugPlay(direction) } else { pages.debugShow(direction, numbers.first ?? 0.5) }
            }
            log("swipe \(argument)")
        case "undo":
            window?.firstResponder?.undoManager?.undo()
        default:
            log("unknown command: \(line)")
        }
    }

    private static func dump() {
        guard let editor else { return }
        let selection = editor.textView.selectedRange()
        let text = editor.text.replacingOccurrences(of: "\n", with: "⏎")
        log("""
        --- dump
        file: \(workspace?.currentURL?.path ?? "none")
        selection: \(selection.location) \(selection.length)
        revealed: \(editor.revealed.map { "\($0.location)+\($0.length)" }.joined(separator: " "))
        activeBlock: \(editor.activeBlock.map(String.init) ?? "none")
        responder: \(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
        scroll: \(Int(editor.scrollView.contentView.bounds.minY)) inset: \(Int(editor.scrollView.contentInsets.top))
        outline: \(workspace?.outline.map { "\($0.level):\($0.title)" }.joined(separator: ", ") ?? "") current: \(workspace?.currentHeading.map(String.init) ?? "title") titleAway: \(workspace?.isTitleScrolledAway == true)
        search: \(workspace?.search.field.stringValue ?? "")
        text: \(text.prefix(4000))
        """)
    }

    private static func sidebarRowPoint(named name: String) -> CGPoint? {
        guard let outline = workspace?.sidebar?.outline, let window, let content = window.contentView else { return nil }
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  cell.textField?.stringValue == name else { continue }
            outline.scrollRowToVisible(row)
            outline.enclosingScrollView?.layoutSubtreeIfNeeded()
            let rect = outline.rect(ofRow: row)
            let inWindow = outline.convert(NSPoint(x: rect.minX + 80, y: rect.midY), to: nil)
            let back = outline.convert(inWindow, from: nil)
            log("row \(row) \(name): rect=\(rect) row at point=\(outline.row(at: back)) flipped=\(outline.isFlipped)")
            return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
        }
        return nil
    }

    /// Where a picture, table or diagram on a line of its own is drawn.
    private static func blockObjectRect(_ editor: EditorController, _ index: Int) -> NSRect? {
        guard let object = editor.layoutManager.object(at: index), object.isBlock else { return nil }
        let layout = editor.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: index)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let style = editor.storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        let size = layout.blockSize(object, at: index, width: line.width - (style?.firstLineHeadIndent ?? 0))
        let origin = editor.textView.textContainerOrigin
        return NSRect(x: line.minX + origin.x, y: line.minY + origin.y + (style?.paragraphSpacingBefore ?? 0), width: size.width, height: size.height)
    }

    private static func windowPoint(ofCharacter index: Int, fraction: Double, in editor: EditorController) -> CGPoint? {
        guard let window, let content = window.contentView, index <= editor.storage.length else { return nil }
        let layout = editor.layoutManager
        let glyph = layout.glyphIndexForCharacter(at: min(index, max(0, editor.storage.length - 1)))
        var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.container)
        if index >= editor.storage.length { rect.origin.x = rect.maxX; rect.size.width = 0 }
        let origin = editor.textView.textContainerOrigin
        let inText = NSPoint(x: rect.minX + rect.width * fraction + origin.x, y: rect.midY + origin.y)
        let inWindow = editor.textView.convert(inText, to: nil)
        return CGPoint(x: inWindow.x, y: content.bounds.height - inWindow.y)
    }

    // MARK: - Events

    /// Clicks by handing the events straight to the view under the point, so it works while Folio is in the
    /// background and never moves the real pointer or takes the focus from what you are doing.
    private static func click(at point: CGPoint, dragTo end: CGPoint? = nil, count: Int = 1, right: Bool = false) {
        guard let window, let content = window.contentView else { return }
        let location = CGPoint(x: point.x, y: content.bounds.height - point.y)
        let endLocation = end.map { CGPoint(x: $0.x, y: content.bounds.height - $0.y) } ?? location
        let root = content.superview ?? content
        guard var target = root.hitTest(location) else { log("click: nothing at \(point)"); return }
        // Rows of a list take their clicks in the list, as a real click does.
        var ancestor: NSView? = target
        while let view = ancestor {
            if view is NSTableView { target = view; break }
            ancestor = view.superview
        }
        func event(_ type: NSEvent.EventType, _ at: CGPoint, clicks: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1)
        }
        // A button over the note (a code block's copy button) tracks clicks with a gesture recognizer, which only sees
        // events the window delivers to a key window: press it the way accessibility does.
        if let button = target as? NSButton, button.superview is NSTextView, end == nil, !right {
            button.performClick(nil)
            log("press \(Int(point.x)),\(Int(point.y)) on \(type(of: button))")
            return
        }
        // SwiftUI controls track clicks through the window, so they get the events the way the window would send them.
        let isAppKitView = sequence(first: target, next: { $0.superview }).contains { $0 is NSTextView || $0 is NSTableView }
        if !isAppKitView, end == nil, !right {
            for click in 1...count {
                if let down = event(.leftMouseDown, location, clicks: click) { window.sendEvent(down) }
                if let up = event(.leftMouseUp, location, clicks: click) { window.sendEvent(up) }
            }
            log("click \(Int(point.x)),\(Int(point.y)) through the window on \(type(of: target))")
            return
        }
        for click in 1...count {
            if end != nil, click == count {
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    let at = CGPoint(x: location.x + (endLocation.x - location.x) * t, y: location.y + (endLocation.y - location.y) * t)
                    if let drag = event(.leftMouseDragged, at, clicks: click) { NSApp.postEvent(drag, atStart: false) }
                }
            }
            if let up = event(.leftMouseUp, end != nil && click == count ? endLocation : location, clicks: click) { NSApp.postEvent(up, atStart: false) }
            if let down = event(.leftMouseDown, location, clicks: click) {
                if window.firstResponder !== target, target.acceptsFirstResponder { window.makeFirstResponder(target) }
                target.mouseDown(with: down)
            }
            // Releases a view handled itself are left in the queue: take them out.
            while NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged], until: .distantPast, inMode: .default, dequeue: true) != nil {}
        }
        log("click \(Int(point.x)),\(Int(point.y))\(end.map { " to \(Int($0.x)),\(Int($0.y))" } ?? "") on \(type(of: target))")
    }

    private static func key(_ argument: String) {
        let bits = argument.split(separator: " ").map(String.init)
        guard let name = bits.first else { return }
        var modifiers: NSEvent.ModifierFlags = []
        if bits.contains("cmd") { modifiers.insert(.command) }
        if bits.contains("shift") { modifiers.insert(.shift) }
        if bits.contains("opt") { modifiers.insert(.option) }
        if bits.contains("ctrl") { modifiers.insert(.control) }
        let table: [String: (String, UInt16)] = [
            "return": ("\r", 36), "tab": ("\t", 48), "space": (" ", 49), "delete": ("\u{7F}", 51), "escape": ("\u{1B}", 53),
            "forwarddelete": (String(UnicodeScalar(NSDeleteFunctionKey)!), 117),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
        ]
        let codes: [String: UInt16] = ["[": 33, "]": 30, ",": 43, "7": 26, "9": 25, "'": 39, "a": 0, "s": 1, "f": 3, "b": 11, "i": 34, "k": 40, "n": 45, "z": 6, "x": 7, "c": 8, "v": 9, "e": 14, "l": 37, "u": 32, "t": 17]
        if let (characters, code) = table[name] {
            if [123, 124, 125, 126].contains(code) { modifiers.insert(.function) }
            sendKey(characters, code: code, modifiers: modifiers)
        } else {
            sendKey(name, code: codes[name] ?? 0, modifiers: modifiers)
        }
    }

    /// Sends a key to Folio's window directly (menus first, for shortcuts), so it works in the background.
    private static func sendKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let window = self.window else { return }
        let ignoring = modifiers.contains(.shift) ? characters.lowercased() : characters
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: modifiers.contains(.shift) ? characters.uppercased() : characters,
                                          charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) else { return }
        if modifiers.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return }
        if !modifiers.contains(.command) || !(window.firstResponder?.performKeyEquivalent(with: down) ?? false) {
            window.sendEvent(down)
        }
        if let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code) {
            window.sendEvent(up)
        }
    }

    // MARK: - Snapshot

    /// The window as a PNG, drawn by the app itself so it works without screen recording permission.
    private static func snapshot(to path: String) {
        guard let window, let view = window.contentView?.superview ?? window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: bitmap)
        // Floating panels (the link popup) are windows of their own.
        let scale = window.backingScaleFactor
        if let cgImage = bitmap.cgImage, let context = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            for child in window.childWindows ?? [] where child.isVisible {
                guard let childView = child.contentView, let childBitmap = childView.bitmapImageRepForCachingDisplay(in: childView.bounds) else { continue }
                childView.cacheDisplay(in: childView.bounds, to: childBitmap)
                if let childImage = childBitmap.cgImage {
                    let x = (child.frame.minX - window.frame.minX) * scale
                    let y = (child.frame.minY - window.frame.minY) * scale
                    context.draw(childImage, in: CGRect(x: x, y: y, width: child.frame.width * scale, height: child.frame.height * scale))
                }
            }
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                log("snapshot \(path)")
                return
            }
        }
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        log("snapshot \(path)")
    }
}
#endif
