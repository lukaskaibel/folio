import AppKit

/// Copying a code block: a button in its corner while the pointer is over it, and Copy Code in its context menu.
/// Only plain code blocks have them; diagrams and formulas don't.
extension EditorController {
    /// The plain code block under a point and the box drawn around it.
    func codeBlock(at point: NSPoint) -> (block: MarkdownBlock, box: NSRect)? {
        guard storage.length > 0, point.y >= visibleTop else { return nil }
        let origin = textView.textContainerOrigin
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: container)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard let blockIndex = document.line(containing: index)?.block, case .code = document.blocks[blockIndex].kind,
              let box = layoutManager.blockBox(at: index, origin: origin), box.contains(point) else { return nil }
        return (document.blocks[blockIndex], box)
    }

    /// Shows the copy button on the code block under the pointer, or hides it when there is none.
    func updateCopyButton(at point: NSPoint?) {
        let button = textView.copyButton
        let hovered = point.flatMap(codeBlock(at:))
        if let hovered { button.frame = CodeCopyButton.frame(in: hovered.box, visibleTop: visibleTop) }
        button.isHidden = hovered == nil
        let start = hovered?.block.range.location
        guard layoutManager.copyButtonBlock != start else { return }
        // The block's language label makes way for the button, and comes back when it goes.
        layoutManager.copyButtonBlock = start
        button.showCopied(false)
        if let box = button.box { textView.setNeedsDisplay(box) }
        button.box = hovered?.box
        if let box = button.box { textView.setNeedsDisplay(box) }
    }

    /// The pointer stayed put while the note moved under it.
    func updateCopyButtonForPointer() {
        guard let window = textView.window, window.isKeyWindow else { return updateCopyButton(at: nil) }
        let point = textView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateCopyButton(at: textView.visibleRect.contains(point) ? point : nil)
    }

    /// Puts the code of the block that starts here on the pasteboard, without its fences.
    @discardableResult
    func copyCode(at start: Int) -> Bool {
        guard let blockIndex = document.line(containing: start)?.block, case .code = document.blocks[blockIndex].kind else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MarkdownStyler.blockContent(nsText, document, document.blocks[blockIndex]), forType: .string)
        return true
    }

    /// Copy Code first in the context menu of a code block.
    func addCopyCode(to menu: NSMenu, at point: NSPoint) {
        guard let (block, _) = codeBlock(at: point) else { return }
        let item = NSMenuItem(title: "Copy Code", action: #selector(MarkdownTextView.copyCodeBlock(_:)), keyEquivalent: "")
        item.representedObject = block.range.location
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }
}

extension MarkdownTextView {
    @objc func copyCodeBlock(_ sender: Any?) {
        guard let start = (sender as? NSMenuItem)?.representedObject as? Int ?? controller?.layoutManager.copyButtonBlock,
              controller?.copyCode(at: start) == true else { return }
        if sender is CodeCopyButton {
            copyButton.showCopied(true)
            NSAccessibility.post(element: copyButton, notification: .announcementRequested, userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

/// The button in the top corner of the code block under the pointer.
@MainActor
final class CodeCopyButton: NSButton {
    /// The box of the code block it is on, in the text view's coordinates.
    var box: NSRect?
    private var reset: DispatchWorkItem?

    static let size = NSSize(width: 24, height: 20)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        imagePosition = .imageOnly
        refusesFirstResponder = true
        isHidden = true
        toolTip = "Copy Code"
        setAccessibilityLabel("Copy Code")
        showCopied(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A tick for a moment after copying, then the copy symbol again.
    func showCopied(_ copied: Bool) {
        reset?.cancel()
        image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        contentTintColor = .secondaryLabelColor
        guard copied else { return }
        let work = DispatchWorkItem { [weak self] in self?.showCopied(false) }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// In the top right of the box, on the line of its opening fence. In a long block whose top went up under the
    /// toolbar it stays in view, inside the box.
    static func frame(in box: NSRect, visibleTop: CGFloat) -> NSRect {
        let y = max(box.minY + 3, min(visibleTop + 6, box.maxY - size.height - 3))
        return NSRect(x: box.maxX - size.width - 6, y: y, width: size.width, height: size.height)
    }
}
