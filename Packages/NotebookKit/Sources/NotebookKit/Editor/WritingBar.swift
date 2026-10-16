#if os(iOS)
import UIKit

/// The bar above the keyboard while you write, as in Notes: text styles and formatting, a checklist, a link, pictures
/// from the camera, the scanner or the library, and a button that puts the keyboard away.
@MainActor
final class WritingBar: UIToolbar {
    private weak var editor: EditorController?

    init(editor: EditorController) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 44))
        autoresizingMask = [.flexibleWidth]
        let format = UIBarButtonItem(title: "Format", image: UIImage(systemName: "textformat"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in completion(self?.formatMenu() ?? []) },
        ]))
        let checklist = UIBarButtonItem(title: "Checklist", image: UIImage(systemName: "checklist"), primaryAction: UIAction { [weak self] _ in
            self?.editor?.perform(.checklist)
        })
        let link = UIBarButtonItem(title: "Link", image: UIImage(systemName: "link"), primaryAction: UIAction { [weak self] _ in
            self?.editor?.perform(.link)
        })
        let attach = UIBarButtonItem(title: "Attach", image: UIImage(systemName: "paperclip"), menu: UIMenu(children: AttachmentSource.available.map { source in
            UIAction(title: source.name, image: UIImage(systemName: source.symbol)) { [weak self] _ in
                guard let editor = self?.editor else { return }
                AttachmentPicker.shared.present(source, for: editor)
            }
        }))
        let done = UIBarButtonItem(title: "Hide Keyboard", image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak self] _ in
            _ = self?.editor?.textView.resignFirstResponder()
        })
        items = [format, checklist, link, attach, .flexibleSpace(), done]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The text styles with the one the caret is in ticked, the formatting as a row of symbols, then lists and
    /// indenting, as Notes' Aa menu has them.
    private func formatMenu() -> [UIMenuElement] {
        guard let editor else { return [] }
        let current = editor.currentLineFormat
        func action(_ command: FormatCommand, checked: Bool = false) -> UIAction {
            UIAction(title: command.name, image: UIImage(systemName: command.symbol), state: checked ? .on : .off) { [weak editor] _ in
                editor?.perform(command)
            }
        }
        let styles = UIMenu(options: .displayInline, children: FormatCommand.styles.map { action($0, checked: $0 == current) })
        let inline = UIMenu(options: .displayInline, preferredElementSize: .small, children: FormatCommand.inline.map { action($0, checked: editor.isActive($0)) })
        let lists = UIMenu(options: .displayInline, children: FormatCommand.lists.map { action($0, checked: $0 == current) })
        let indent = UIMenu(options: .displayInline, preferredElementSize: .medium, children: [action(.outdent), action(.indent)])
        return [inline, styles, lists, indent]
    }
}
#endif
