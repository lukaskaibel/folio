#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Pictures and file cards in a note, by touch, as Notes has them: a tap opens one; touching and holding selects it,
/// with the ring the Mac draws, and shows what you can do with it; moving the finger then lifts it, to drop it
/// elsewhere in the note or in another app.
@MainActor
final class PictureInteractions: NSObject, UIContextMenuInteractionDelegate, UIDragInteractionDelegate {
    private weak var editor: EditorController?

    /// What is dragged: the picture's Markdown and where it was, in the note it came from.
    final class Drag {
        let range: NSRange
        let markdown: String
        let note: Int
        init(range: NSRange, markdown: String, note: Int) {
            self.range = range
            self.markdown = markdown
            self.note = note
        }
    }

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
        let before = Set(textView.gestureRecognizers ?? [])
        textView.addInteraction(UIContextMenuInteraction(delegate: self))
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        textView.addInteraction(drag)
        textView.pictureRecognizers = Set(textView.gestureRecognizers ?? []).subtracting(before)
    }

    /// The picture or file card at a point in the text view.
    func picture(at point: CGPoint) -> Picture? {
        guard let editor, !editor.isDrawing, case .picture(let range, let url) = editor.hitTest(point),
              let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) else { return nil }
        return Picture(range: range, url: url, rect: rect)
    }

    // MARK: - Touch and hold

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let editor, let picture = picture(at: location) else { return nil }
        editor.selectObject(picture.range)
        return UIContextMenuConfiguration(identifier: NSValue(range: picture.range), previewProvider: nil) { [weak self] _ in
            self?.menu(for: picture)
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let range = (identifier as? NSValue)?.rangeValue, let picture = picture(at: range) else { return nil }
        return preview(of: picture)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        guard let range = (identifier as? NSValue)?.rangeValue, let picture = picture(at: range) else { return nil }
        return preview(of: picture)
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
        guard let editor, let view = interaction.view, let picture = picture(at: session.location(in: view)) else { return [] }
        let markdown = editor.nsText.substring(with: picture.range)
        // Another app gets the file itself; this note moves the Markdown.
        let provider = picture.url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider(object: markdown as NSString)
        provider.suggestedName = picture.url?.deletingPathExtension().lastPathComponent
        let item = UIDragItem(itemProvider: provider)
        item.localObject = Drag(range: picture.range, markdown: markdown, note: editor.loadCount)
        editor.selectObject(picture.range)
        return [item]
    }

    func dragInteraction(_ interaction: UIDragInteraction, previewForLifting item: UIDragItem, session: UIDragSession) -> UITargetedDragPreview? {
        guard let drag = item.localObject as? Drag, let picture = picture(at: drag.range), let preview = preview(of: picture) else { return nil }
        return UITargetedDragPreview(view: preview.view, parameters: preview.parameters as! UIDragPreviewParameters, target: preview.target)
    }

    func dragInteraction(_ interaction: UIDragInteraction, sessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool {
        false
    }

    // MARK: - Previews

    private func picture(at range: NSRange) -> Picture? {
        guard let editor, range.upperBound <= editor.storage.length,
              let rect = editor.layoutManager.rect(forObjectAt: range.location, origin: editor.textOrigin) else { return nil }
        return picture(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// The picture as it is drawn, lifted off the page with its rounded corners.
    private func preview(of picture: Picture) -> UITargetedPreview? {
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

    /// A picture dropped elsewhere in its note: it goes on a line of its own before the line it was dropped on, in
    /// one change that one undo takes back.
    func moveObject(_ range: NSRange, to location: Int) {
        let text = nsText
        guard range.upperBound <= text.length else { return }
        let markdown = text.substring(with: range)
        let removal = blockRange(of: range)
        var target = text.lineRange(for: NSRange(location: min(location, text.length), length: 0)).location
        var inserted = markdown + "\n"
        if location >= text.length, text.length > 0, !text.hasSuffix("\n") {
            target = text.length
            inserted = "\n" + markdown
        }
        guard target < removal.location || target > removal.upperBound else { return }
        let lead = inserted.hasPrefix("\n") ? 1 : 0
        let length = (markdown as NSString).length
        if target < removal.location {
            let between = text.substring(with: NSRange(location: target, length: removal.location - target))
            replace(NSRange(location: target, length: removal.upperBound - target), with: inserted + between,
                    select: NSRange(location: target + lead, length: length), actionName: "Move")
        } else {
            let between = text.substring(with: NSRange(location: removal.upperBound, length: target - removal.upperBound))
            let start = removal.location + (between as NSString).length + lead
            replace(NSRange(location: removal.location, length: target - removal.location), with: between + inserted,
                    select: NSRange(location: start, length: length), actionName: "Move")
        }
        selectionChanged()
    }

    /// A picture of this note dragged within it.
    func pictureDrag(in drop: UITextDropRequest) -> PictureInteractions.Drag? {
        guard let drag = drop.dropSession.localDragSession?.items.first?.localObject as? PictureInteractions.Drag,
              drag.note == loadCount, drag.range.upperBound <= storage.length,
              nsText.substring(with: drag.range) == drag.markdown else { return nil }
        return drag
    }
}
#endif
