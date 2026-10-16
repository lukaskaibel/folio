#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Pictures and file cards in a note, by touch, as in Notes: a tap opens one; touching and holding lifts it, to drop
/// elsewhere in the note or in another app; let go without moving and it is selected, with the ring the Mac draws,
/// and the edit menu shows what you can do with it. Selected text is the text view's own to drag (see
/// `EditorController.textDraggableView`).
@MainActor
final class PictureInteractions: NSObject, UIDragInteractionDelegate, @preconcurrency UIEditMenuInteractionDelegate {
    private weak var editor: EditorController?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    /// The picture held, and where the finger was when it lifted.
    private var held: (picture: Picture, start: CGPoint)?
    private var heldMoved = false
    /// The picture the edit menu is for.
    private var menuPicture: Picture?

    struct Picture {
        let range: NSRange
        let url: URL?
        /// Where it is drawn, in the text view.
        let rect: CGRect
    }

    init(editor: EditorController) {
        self.editor = editor
        super.init()
    }

    func install(on textView: MarkdownTextView) {
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        textView.addInteraction(drag)
        textView.addInteraction(editMenu)
    }

    /// The picture or file card at a point in the text view.
    func picture(at point: CGPoint) -> Picture? {
        guard let editor, !editor.isDrawing, case .picture(let range, let url) = editor.hitTest(point),
              let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) else { return nil }
        return Picture(range: range, url: url, rect: rect)
    }

    // MARK: - The edit menu

    /// Selects the picture and shows its menu above it, as a text view shows one for selected text.
    func showMenu(for picture: Picture) {
        editor?.selectObject(picture.range)
        menuPicture = picture
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: picture.rect.midX, y: picture.rect.minY)))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        menuPicture.map(menu(for:))
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuPicture?.rect ?? .null
    }

    private func menu(for picture: Picture) -> UIMenu {
        guard let editor else { return UIMenu() }
        var open: [UIMenuElement] = []
        if let drawing = editor.drawing(at: picture.range) {
            open.append(UIAction(title: "Edit Drawing", image: UIImage(systemName: "pencil.tip.crop.circle")) { [weak editor] _ in
                editor?.beginDrawing(in: drawing)
            })
        }
        if let url = picture.url {
            open.append(UIAction(title: "Quick Look", image: UIImage(systemName: "eye")) { [weak editor] _ in
                guard let editor else { return }
                editor.delegate?.editor(editor, quickLook: url)
            })
        }
        let copy = UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak editor] _ in
            editor?.setSelection(picture.range)
            _ = editor?.copySelection(cut: false)
        }
        let cut = UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak editor] _ in
            editor?.setSelection(picture.range)
            _ = editor?.copySelection(cut: true)
        }
        var edit: [UIMenuElement] = [copy, cut]
        if let url = picture.url {
            edit.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.share(url, from: picture.rect)
            })
        }
        let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak editor] _ in
            editor?.deleteObject(picture.range)
        }
        _ = editor
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: open),
            UIMenu(options: .displayInline, children: edit),
            UIMenu(options: .displayInline, children: [delete]),
        ])
    }

    private func share(_ url: URL, from rect: CGRect) {
        guard let textView = editor?.textView, let root = textView.window?.rootViewController else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = textView
        controller.popoverPresentationController?.sourceRect = rect
        root.topmostPresented.present(controller, animated: true)
    }

    // MARK: - Dragging

    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard let editor, let view = interaction.view else { return [] }
        let point = session.location(in: view)
        if let picture = picture(at: point) {
            editMenu.dismissMenu()
            held = (picture, point)
            heldMoved = false
            editor.selectObject(picture.range)
            return editor.dragItem(for: picture.range).map { [$0] } ?? []
        }
        held = nil
        return []
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        guard let drag = item.localObject as? EditorController.Drag else { return nil }
        if drag.isObject, let picture = picture(at: drag.range), let preview = preview(of: picture),
           let parameters = preview.parameters as? UIDragPreviewParameters {
            return UITargetedDragPreview(view: preview.view, parameters: parameters, target: preview.target)
        }
        return nil
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        false
    }

    /// Held and let go without moving: the lift goes back, the picture stays selected and its menu shows.
    func dragInteraction(_ interaction: UIDragInteraction, willAnimateLiftWith animator: any UIDragAnimating, session: UIDragSession) {
        animator.addCompletion { [weak self] position in
            guard let self, position == .start, let held = self.held, !self.heldMoved,
                  let current = self.picture(at: held.picture.range) else { return }
            self.held = nil
            self.showMenu(for: current)
        }
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionDidMove session: UIDragSession) {
        guard let held, let view = interaction.view else { return }
        let point = session.location(in: view)
        if hypot(point.x - held.start.x, point.y - held.start.y) > 8 { heldMoved = true }
    }

    func dragInteraction(_ interaction: UIDragInteraction, session: UIDragSession, didEndWith operation: UIDropOperation) {
        held = nil
    }

    // MARK: - Previews

    func picture(at range: NSRange) -> Picture? {
        guard let editor, range.upperBound <= editor.storage.length,
              let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) else { return nil }
        return picture(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The picture as it is drawn, lifted off the page with its rounded corners.
    func preview(of picture: Picture) -> UITargetedPreview? {
        guard let textView = editor?.textView,
              let snapshot = textView.resizableSnapshotView(from: picture.rect, afterScreenUpdates: false, withCapInsets: .zero) else { return nil }
        let parameters = UIDragPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: picture.rect.size), cornerRadius: 8)
        parameters.backgroundColor = .clear
        let target = UIPreviewTarget(container: textView, center: CGPoint(x: picture.rect.midX, y: picture.rect.midY))
        return UITargetedPreview(view: snapshot, parameters: parameters, target: target)
    }
}

extension EditorController {
    /// Selects a picture or file card whole: the ring shows around it, not the text's selection.
    func selectObject(_ range: NSRange) {
        setSelection(range)
        selectionChanged()
    }

    /// Whether the range is exactly one picture, file card or other block drawn in place of its Markdown.
    func isWholeObject(_ range: NSRange) -> Bool {
        guard range.length > 0, range.upperBound <= storage.length, let object = layoutManager.object(at: range.location) else { return false }
        return object.isBlock && object.range(at: range.location) == range
    }

    /// What goes when an object goes: its whole line when it is alone on one, so no empty line stays behind.
    private func blockRange(of range: NSRange) -> NSRange {
        let text = nsText
        let line = text.lineRange(for: range)
        let content = text.substring(with: line).trimmingCharacters(in: .newlines)
        guard content == text.substring(with: range) else { return range }
        // The last line, without a line break of its own, takes the one before it.
        if !text.substring(with: line).hasSuffix("\n"), line.location > 0 {
            return NSRange(location: line.location - 1, length: line.length + 1)
        }
        return line
    }

    func deleteObject(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        let removal = blockRange(of: range)
        replace(removal, with: "", select: NSRange(location: removal.location, length: 0), actionName: "Delete")
    }

    /// A picture dropped elsewhere in its note goes before the line it was dropped on, as a paragraph of its own: a
    /// blank line between it and text, and no blank line left doubled where it was. One change, which one undo takes
    /// back.
    func moveObject(_ range: NSRange, to location: Int) {
        let text = nsText
        guard range.upperBound <= text.length else { return }
        let markdown = text.substring(with: range)
        func isBlank(_ line: NSRange) -> Bool { text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func line(at index: Int) -> NSRange { text.lineRange(for: NSRange(location: index, length: 0)) }

        var removal = blockRange(of: range)
        if removal != range, removal.upperBound < text.length, isBlank(line(at: removal.upperBound)),
           removal.location == 0 || isBlank(line(at: removal.location - 1)) {
            removal.length += line(at: removal.upperBound).length
        }
        var target = line(at: min(location, text.length)).location
        if location >= text.length, text.length > 0 { target = text.length }
        guard target < removal.location || target > removal.upperBound else { return }

        let atEnd = target == text.length
        let before = target > 0 && !isBlank(line(at: target - 1)) && !(atEnd && text.hasSuffix("\n\n"))
        var lead = before ? "\n" : ""
        if atEnd, text.length > 0, !text.hasSuffix("\n") { lead = "\n\n" }
        let after = !atEnd && !isBlank(line(at: target))
        let inserted = lead + markdown + "\n" + (after ? "\n" : "")

        // Both changes as one: the stretch from the first to the last, rewritten.
        let low = min(target, removal.location)
        let high = max(target, removal.upperBound)
        let stretch = NSMutableString(string: text.substring(with: NSRange(location: low, length: high - low)))
        let removed = NSRange(location: removal.location - low, length: removal.length)
        var start: Int
        if target < removal.location {
            stretch.replaceCharacters(in: removed, with: "")
            stretch.insert(inserted, at: target - low)
            start = target
        } else {
            stretch.insert(inserted, at: target - low)
            stretch.replaceCharacters(in: removed, with: "")
            start = target - removal.length
        }
        start += (lead as NSString).length
        replace(NSRange(location: low, length: high - low), with: stretch as String,
                select: NSRange(location: start, length: (markdown as NSString).length), actionName: "Move")
        selectionChanged()
    }

    /// Text moved by dragging within the note: taken out and put in where it was dropped, in one change that one undo
    /// takes back.
    func moveText(_ range: NSRange, to location: Int) {
        let text = nsText
        guard range.upperBound <= text.length, location <= text.length, location < range.location || location > range.upperBound else { return }
        let markdown = text.substring(with: range)
        if location < range.location {
            let between = text.substring(with: NSRange(location: location, length: range.location - location))
            replace(NSRange(location: location, length: range.upperBound - location), with: markdown + between,
                    select: NSRange(location: location, length: range.length), actionName: "Move")
        } else {
            let between = text.substring(with: NSRange(location: range.upperBound, length: location - range.upperBound))
            replace(NSRange(location: range.location, length: location - range.location), with: between + markdown,
                    select: NSRange(location: range.location + (between as NSString).length, length: range.length), actionName: "Move")
        }
    }
}
#endif
