#if DEBUG && os(iOS)
import SwiftUI
import UIKit

/// Development-only remote control for iPhone and iPad, as on the Mac. Launch with `-debugCommandFile <path>` (a `~`
/// is the app's home in the Simulator) and append lines to that file to drive the app: open files, type, press keys,
/// tap things in a note, search, go back. Results go to `<path>.log`. Screenshots come from `xcrun simctl io`.
@MainActor
enum DebugRemote {
    private static var processed = 0
    private static var timer: Timer?
    private static weak var workspace: Workspace?
    private static var path = ""
    private static var waitUntil: Date?

    static func startIfRequested(workspace: Workspace) {
        guard timer == nil, let file = UserDefaults.standard.string(forKey: "debugCommandFile") else { return }
        self.workspace = workspace
        path = (file as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        processed = max(0, ((try? String(contentsOfFile: path, encoding: .utf8))?.components(separatedBy: "\n").count ?? 1) - 1)
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log("ready \(path)")
    }

    private static func poll() {
        if let waitUntil, Date() < waitUntil { return }
        waitUntil = nil
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\n")
        while processed < lines.count - 1 {
            let line = lines[processed]
            processed += 1
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            run(line)
            if waitUntil != nil { return }
        }
    }

    static func log(_ text: String) {
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

    private static func url(_ argument: String) -> URL? {
        if argument.hasPrefix("/") { return URL(fileURLWithPath: argument) }
        return workspace?.locations.first?.url.appendingPathComponent(argument)
    }

    private static func run(_ line: String) {
        guard let workspace else { return }
        let editor = workspace.editor
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0]
        let argument = parts.count > 1 ? parts[1] : ""
        let numbers = argument.split(separator: " ").compactMap { Double($0) }
        switch command {
        case "wait":
            waitUntil = Date().addingTimeInterval(numbers.first ?? 0.5)
        case "open":
            if let url = url(argument) { workspace.open(url) }
        case "close":
            workspace.closeFile()
        case "newnote":
            workspace.newNote(title: argument.isEmpty ? nil : argument)
        case "focus":
            editor.focusText(atEnd: argument == "end")
        case "focustitle":
            editor.focusTitle()
        case "blur":
            editor.endEditing()
        case "type":
            for character in argument.replacingOccurrences(of: "\\n", with: "\n") { editor.debugType(String(character)) }
        case "key":
            switch argument {
            case "return": editor.debugType("\n")
            case "backspace": editor.debugBackspace()
            case "tab": editor.debugType("\t")
            case "up": _ = editor.moveUpIntoTitle()
            default: log("unknown key \(argument)")
            }
        case "select":
            if numbers.count == 2 { editor.setSelection(NSRange(location: Int(numbers[0]), length: Int(numbers[1]))) }
        case "find":
            // Puts the caret at the start of some text in the note.
            let range = (editor.text as NSString).range(of: argument)
            if range.location != NSNotFound { editor.setSelection(NSRange(location: range.location, length: 0)) }
        case "tapobject":
            // A tap on whatever is drawn at the start of some text (a checkbox, a link, a picture).
            let range = (editor.text as NSString).range(of: argument)
            guard range.location != NSNotFound else { return log("not found: \(argument)") }
            if let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) {
                editor.debugTap(at: CGPoint(x: rect.midX, y: rect.midY))
            } else {
                let glyph = editor.layoutManager.glyphIndexForCharacter(at: range.location)
                let rect = editor.layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: editor.container)
                editor.debugTap(at: CGPoint(x: rect.midX + editor.textOrigin.x, y: rect.midY + editor.textOrigin.y))
            }
        case "format":
            if let format = FormatCommand.allCases.first(where: { $0.name.lowercased().replacingOccurrences(of: " ", with: "") == argument.lowercased() }) {
                editor.perform(format)
            }
        case "scroll":
            editor.setScrollTop((numbers.first ?? 0) - editor.topInset)
        case "scrollto":
            editor.scroll(to: editor.outline[safe: Int(numbers.first ?? 0)], animated: false)
        case "undo":
            editor.textView.undoManager?.undo()
        case "redo":
            editor.textView.undoManager?.redo()
        case "outline":
            workspace.isOutlineVisible.toggle()
        case "sidebar":
            workspace.columnVisibility = argument == "hide" ? .detailOnly : .all
        case "favorite":
            if let url = url(argument) ?? workspace.currentURL { workspace.toggleFavorite(url) }
        case "rename":
            if let url = workspace.currentURL { workspace.rename(url, to: argument) }
        case "export":
            Task {
                let file = await NoteExporter.pdfFile(for: editor, title: workspace.currentTitle)
                log("exported \(file?.path ?? "nothing")")
            }
        case "dump":
            log("current \(workspace.currentURL?.path ?? "none") editing \(workspace.isEditing) selection \(editor.selection) scroll \(editor.scrollTop) top \(editor.topInset) titleAway \(workspace.isTitleScrolledAway) heading \(String(describing: workspace.currentHeading))")
        case "text":
            log(editor.text)
        case "suggestions":
            log("suggestions \(editor.suggestions.isVisible) \(editor.suggestions.model.items.map(\.title))")
        case "views":
            if let window = editor.textView.window { log(describe(window, depth: 0, limit: Int(numbers.first ?? 6))) }
        default:
            // Everything else is the screens': going back, searching, showing settings.
            NotificationCenter.default.post(name: .folioDebug, object: nil, userInfo: ["command": command, "argument": argument])
        }
    }

    private static func describe(_ view: UIView, depth: Int, limit: Int) -> String {
        guard depth <= limit else { return "" }
        var line = String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral)"
        if let label = view.accessibilityLabel { line += " “\(label)”" }
        return ([line] + view.subviews.map { describe($0, depth: depth + 1, limit: limit) }.filter { !$0.isEmpty }).joined(separator: "\n")
    }
}

extension Notification.Name {
    /// A debug remote command for the screens.
    static let folioDebug = Notification.Name("FolioDebug")
}

extension EditorController {
    /// A key of the keyboard: the keyboard asks the text view's delegate before it types, as this does.
    func debugType(_ text: String) {
        let range = selection
        if textView(textView, shouldChangeTextIn: range, replacementText: text) { textView.insertText(text) }
    }

    func debugBackspace() {
        let selection = selection
        let range = selection.length > 0 ? selection : (nsText as NSString).rangeOfComposedCharacterSequence(at: max(0, selection.location - 1))
        guard selection.length > 0 || selection.location > 0 else { return }
        if textView(textView, shouldChangeTextIn: range, replacementText: "") { textView.deleteBackward() }
    }

    /// A tap at a point in the text view, as the tap recognizer gets one.
    func debugTap(at point: CGPoint) {
        guard let hit = hitTest(point) else { return DebugRemote.log("nothing at \(point)") }
        DebugRemote.log("tap \(hit)")
        handleTap(hit, at: point)
    }
}
#endif
