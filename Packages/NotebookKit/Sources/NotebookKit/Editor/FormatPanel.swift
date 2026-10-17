#if os(iOS)
import SwiftUI
import UIKit

/// What the Format panel shows picked: the style of the caret's line and the formatting the caret is in.
@MainActor
@Observable
final class FormatState {
    var line: FormatCommand? = .body
    var active: Set<FormatCommand> = []

    func update(from editor: EditorController) {
        let line = editor.currentLineFormat
        let active = Set(FormatCommand.inline.filter(editor.isActive))
        if line != self.line { self.line = line }
        if active != self.active { self.active = active }
    }
}

/// The Format panel, as in Notes: the text styles in a row, then the formatting, then lists and indenting. What the
/// caret is in shows picked, and a tap applies to the caret's line or the selection while the panel stays.
struct FormatPanelView: View {
    let editor: EditorController
    let close: () -> Void
    @State private var width: CGFloat = 360

    private var state: FormatState { editor.formatState }
    private static let rows: [[[FormatCommand]]] = [
        [[.bold, .italic, .strikethrough, .code], [.highlight, .link]],
        [[.checklist, .bulletedList, .numberedList], [.outdent, .indent], [.quote]],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Format")
                    .font(.title2.weight(.bold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Close")
            }
            styles
            ForEach(Self.rows.indices, id: \.self) { index in
                row(Self.rows[index])
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 40 } action: { width = $0 }
        .onAppear { state.update(from: editor) }
    }

    /// Title, Heading, Subheading and Body, each set as it is in the note.
    private var styles: some View {
        let face = NotebookSettings.shared.typography.face
        return ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(FormatCommand.styles) { style in
                    let isOn = state.line == style
                    Button { apply(style) } label: {
                        Text(style.name)
                            .font(Font(EditorStyle.styleSample(style, size: 15, face: face)))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                            .background(isOn ? Color(Theme.accent) : Color.clear, in: .capsule)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Groups of buttons, each group a capsule; every button as wide as the others in the row.
    private func row(_ groups: [[FormatCommand]]) -> some View {
        let count = CGFloat(groups.joined().count)
        let gaps = CGFloat(groups.count - 1) * 10 + (count - CGFloat(groups.count)) * 2
        let buttonWidth = max(30, (width - gaps) / count)
        return HStack(spacing: 10) {
            ForEach(groups.indices, id: \.self) { index in
                HStack(spacing: 2) {
                    ForEach(groups[index]) { command in
                        button(command, width: buttonWidth)
                    }
                }
                .clipShape(.capsule)
            }
        }
    }

    private func button(_ command: FormatCommand, width: CGFloat) -> some View {
        let isOn = state.active.contains(command) || (state.line == command && FormatCommand.lists.contains(command))
        return Button { apply(command) } label: {
            Image(systemName: command.symbol)
                .font(.system(size: 18, weight: .medium))
                .frame(width: width, height: 46)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color(Theme.accent) : Color(.tertiarySystemFill))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(command.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func apply(_ command: FormatCommand) {
        editor.beginEditing(then: command)
        state.update(from: editor)
    }
}

/// The Format panel where the keyboard was, as Notes has it: the caret stays in the text, so what you pick applies
/// there, and closing the panel brings the keyboard back.
final class FormatInputView: UIInputView {
    init(editor: EditorController) {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 280), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let host = UIHostingController(rootView: FormatPanelView(editor: editor) { [weak editor] in editor?.hideFormatPanel() })
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.view.topAnchor.constraint(equalTo: topAnchor),
            host.view.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension EditorController {
    var isShowingFormatPanel: Bool { textView.inputView != nil }

    func toggleFormatPanel() {
        isShowingFormatPanel ? hideFormatPanel() : showFormatPanel()
    }

    /// Aa in the bar above the keyboard: the Format panel takes the keyboard's place, and the bar goes with it.
    func showFormatPanel() {
        formatState.update(from: self)
        if formatInput == nil { formatInput = FormatInputView(editor: self) }
        textView.inputView = formatInput
        textView.inputAccessoryView = nil
        if textView.isFirstResponder {
            textView.reloadInputViews()
        } else {
            makeTextFirstResponder()
        }
    }

    func hideFormatPanel() {
        guard isShowingFormatPanel else { return }
        textView.inputView = nil
        textView.inputAccessoryView = writingBar
        if textView.isFirstResponder { textView.reloadInputViews() }
    }

    /// The heading level in the margin, tapped: Title, Heading, Subheading and Body in a popover next to it, since a
    /// menu can't set each as it is in the note.
    func showTextStyles() {
        guard headingMarkLevel != nil, let current = currentLineFormat,
              let presenter = textView.window?.rootViewController?.topmostPresented else { return }
        let host = UIHostingController(rootView: TextStyleList(current: current) { [weak self, weak presenter] style in
            self?.perform(style)
            presenter?.dismiss(animated: true)
        })
        host.sizingOptions = .preferredContentSize
        host.modalPresentationStyle = .popover
        if let popover = host.popoverPresentationController {
            popover.sourceView = textView.headingButton
            popover.sourceRect = textView.headingButton.bounds
            popover.permittedArrowDirections = [.left, .up, .down]
            popover.delegate = PopoverOnPhone.shared
        }
        presenter.present(host, animated: true)
    }
}

/// The text styles as a menu lists them, the one the line has ticked, but each set as it is in the note.
struct TextStyleList: View {
    let current: FormatCommand
    let pick: (FormatCommand) -> Void

    var body: some View {
        let face = NotebookSettings.shared.typography.face
        VStack(spacing: 0) {
            ForEach(FormatCommand.styles) { style in
                let isOn = style == current
                Button { pick(style) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 20)
                            .opacity(isOn ? 1 : 0)
                        Text(style.name)
                            .font(Font(EditorStyle.styleSample(style, size: 17, face: face)))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 46)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .frame(width: 230)
    }
}

/// Keeps a popover a popover where the screen is narrow, rather than a sheet.
@MainActor
final class PopoverOnPhone: NSObject, UIPopoverPresentationControllerDelegate {
    static let shared = PopoverOnPhone()

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
#endif
