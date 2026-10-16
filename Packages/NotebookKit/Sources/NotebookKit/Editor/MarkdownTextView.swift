#if os(macOS)
import AppKit

/// The note's text view. Mouse, keyboard and pasteboard go through the `EditorController`; this class only adds what
/// has to live in the view: tracking the mouse, the caret, the title above the text and centring the text column.
@MainActor
final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?

    /// True while the mouse button is down and AppKit is tracking a click or drag. Markdown doesn't show next to the
    /// caret until the button comes up, so selecting never moves text around under the pointer.
    private(set) var isTrackingMouse = false

    let titleField = TitleField()
    let metaLabel = NSTextField(labelWithString: "")
    let copyButton = CodeCopyButton()

    static let titleTop: CGFloat = 44
    static let titleHeight: CGFloat = 40
    static let headerHeight: CGFloat = 112

    /// Set on a copy laid out for export or printing: this much margin all round, and no date under the title.
    var exportMargin: CGFloat? {
        didSet {
            metaLabel.isHidden = exportMargin != nil
            updateInsets()
        }
    }

    private var titleTop: CGFloat { exportMargin ?? Self.titleTop }
    var headerHeight: CGFloat { exportMargin.map { $0 + Self.titleHeight + 18 } ?? Self.headerHeight }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        titleField.textColor = Theme.text
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.isScrollable = true
        titleField.setAccessibilityLabel("Title")
        addSubview(titleField)
        metaLabel.font = .systemFont(ofSize: 12.5)
        metaLabel.textColor = Theme.textTertiary
        addSubview(metaLabel)
        copyButton.target = self
        copyButton.action = #selector(copyCodeBlock(_:))
        addSubview(copyButton)
        applyTypography()
    }

    /// The title in the note's typeface; the width of the text follows the settings too.
    func applyTypography() {
        let font = EditorStyle.face(30, weight: .bold)
        titleField.font = font
        titleField.placeholderAttributedString = NSAttributedString(string: "Untitled", attributes: [.font: font, .foregroundColor: Theme.faint])
        updateInsets()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    /// Centres a column of text at most `EditorStyle.contentWidth` wide, with room above for the title.
    func updateInsets() {
        let side = exportMargin ?? max(52, floor((bounds.width - EditorStyle.contentWidth) / 2))
        let inset = NSSize(width: side, height: headerHeight)
        if textContainerInset != inset { textContainerInset = inset }
        let width = bounds.width - side * 2
        titleField.frame = NSRect(x: side - 2, y: titleTop, width: width + 4, height: Self.titleHeight)
        metaLabel.frame = NSRect(x: side, y: titleTop + Self.titleHeight + 2, width: width, height: 18)
    }

    // Leave more room under the last line than above the title.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: headerHeight)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if controller?.handleMouseDown(event) == true { return }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        controller?.mouseTrackingEnded()
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.updateCopyButton(at: convert(event.locationInWindow, from: nil))
        controller?.updateCursor(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.updateCopyButton(at: nil)
    }

    // AppKit puts the I-beam back on every cursor update; links and checkboxes keep the hand.
    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        controller?.updateCursor(for: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.contextMenu(for: event, base: super.menu(for: event)) ?? super.menu(for: event)
    }

    // The pointer isn't tracked in a window in the background, so nothing would hide the copy button there.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowResignedKey() {
        controller?.updateCopyButton(at: nil)
    }

    #if DEBUG
    /// For recordings of a window in the background, which draws no caret of its own.
    static var drawsCaretAlways = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard Self.drawsCaretAlways, selectedRange().length == 0, window?.firstResponder === self,
              let window, var rect = Optional(firstRect(forCharacterRange: selectedRange(), actualRange: nil)) else { return }
        rect = convert(window.convertFromScreen(rect), from: nil)
        let caret = controller?.caretRect(proposed: NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)) ?? rect
        insertionPointColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height), xRadius: 1, yRadius: 1).fill()
    }
    #endif

    // The margin is the view's to draw: the text system only draws inside the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        controller?.drawMarginMarks(in: rect)
    }

    // MARK: - Caret

    /// A caret as tall as the text it is in, not as the line, which is taller than the font.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let caret = controller?.caretRect(proposed: rect) ?? rect
        if flag {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height), xRadius: 1, yRadius: 1).fill()
        } else {
            super.drawInsertionPoint(in: rect.union(NSRect(x: caret.minX, y: caret.minY, width: 2, height: caret.height)), color: color, turnedOn: false)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -2, dy: 0), avoidAdditionalLayout: flag)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { controller?.focusChanged() }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { controller?.focusChanged() }
        return result
    }

    // MARK: - Pasteboard

    override func copy(_ sender: Any?) {
        if controller?.copySelection(cut: false) != true { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        if controller?.copySelection(cut: true) != true { super.cut(sender) }
    }

    override func paste(_ sender: Any?) {
        if controller?.paste(from: .general, at: nil) != true { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if let string = NSPasteboard.general.string(forType: .string) { insertText(string, replacementRange: selectedRange()) }
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff, .string, EditorController.fragmentType] + super.readablePasteboardTypes
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        // Dragging text inside the note is AppKit's; files and pictures from elsewhere are the editor's.
        if sender.draggingSource as? NSTextView !== self, controller?.paste(from: sender.draggingPasteboard, at: index) == true {
            return true
        }
        return super.performDragOperation(sender)
    }

    // MARK: - Keys the menus don't cover

    override func keyDown(with event: NSEvent) {
        if controller?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }
}

/// The title above the note: the file's name, renamed when you change it.
final class TitleField: NSTextField {
    var onCommandBy: ((Selector) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
}
#endif
