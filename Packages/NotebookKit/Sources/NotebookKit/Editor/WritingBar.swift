#if os(iOS)
import SwiftUI
import UIKit

/// What the bar above the keyboard can hold. Which ones and in what order is yours to choose, in Settings › Writing
/// Bar.
enum WritingTool: String, CaseIterable, Identifiable {
    case format, checklist, attach, drawing, link, undo, redo
    case bold, italic, strikethrough, highlight, code, quote
    case bulletedList, numberedList, outdent, indent
    case camera, scanner, photos, files
    case reminder
    case hideKeyboard

    var id: Self { self }

    /// The bar as it comes: what Notes has first, then the formatting, then lists and pictures.
    static let standard: [WritingTool] = [
        .format, .checklist, .attach, .drawing, .link, .undo, .redo,
        .bold, .italic, .strikethrough, .highlight, .code, .quote,
        .bulletedList, .numberedList, .outdent, .indent, .camera, .scanner,
    ]

    var command: FormatCommand? {
        switch self {
        case .checklist: .checklist
        case .link: .link
        case .bold: .bold
        case .italic: .italic
        case .strikethrough: .strikethrough
        case .highlight: .highlight
        case .code: .code
        case .quote: .quote
        case .bulletedList: .bulletedList
        case .numberedList: .numberedList
        case .outdent: .outdent
        case .indent: .indent
        default: nil
        }
    }

    var source: AttachmentSource? {
        switch self {
        case .camera: .camera
        case .scanner: .scanner
        case .photos: .photos
        case .files: .files
        default: nil
        }
    }

    var name: String {
        if let command { return command.name }
        if let source { return source.name }
        switch self {
        case .format: return "Format"
        case .attach: return "Attach"
        case .drawing: return "Drawing"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .reminder: return "Remind Me"
        default: return "Hide Keyboard"
        }
    }

    var symbol: String {
        if let command { return command.symbol }
        if let source { return source == .files ? "folder" : source.symbol }
        switch self {
        case .format: return "textformat"
        case .attach: return "paperclip"
        case .drawing: return "pencil.tip.crop.circle"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .reminder: return "bell"
        default: return "keyboard.chevron.compact.down"
        }
    }

    /// The camera and the scanner only where there is a camera.
    var isAvailable: Bool { source?.isAvailable ?? true }
}

/// The bar above the keyboard while you write, as in Notes: the tools float over the note in a capsule of glass, a
/// little above the keyboard, and the ones that don't fit wait on the next page.
@MainActor
final class WritingBar: UIView {
    /// Room above the capsule, the capsule, and the gap between it and the keyboard.
    static let topGap: CGFloat = 6
    static let barHeight: CGFloat = 44
    static let keyboardGap: CGFloat = 10
    static let height = topGap + barHeight + keyboardGap
    /// About a fingertip per tool; a page holds as many as fit.
    static let toolWidth: CGFloat = 56

    /// The capsule spans the screen on an iPhone, less its margins; on a wider screen it stops at about ten tools.
    static func barWidth(for available: CGFloat) -> CGFloat {
        max(toolWidth, min(available - 24, 620))
    }

    private let host: UIHostingController<WritingBarView>
    private weak var editor: EditorController?

    init(editor: EditorController) {
        self.editor = editor
        host = UIHostingController(rootView: WritingBarView(editor: editor))
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height))
        autoresizingMask = [.flexibleWidth]
        backgroundColor = .clear
        host.view.backgroundColor = .clear
        host.safeAreaRegions = []
        host.view.frame = bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(host.view)
        // Touch and hold the bar to change it. SwiftUI's context menu doesn't come up in the keyboard's window.
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    /// Only the capsule takes touches: the strip around it belongs to the note.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let width = Self.barWidth(for: bounds.width)
        let capsule = CGRect(x: (bounds.width - width) / 2, y: Self.topGap, width: width, height: Self.barHeight)
        return capsule.insetBy(dx: -4, dy: -4).contains(point)
    }
}

extension WritingBar: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [
                UIAction(title: "Edit Writing Bar…", image: UIImage(systemName: "slider.horizontal.3")) { _ in self?.editor?.editWritingBar() },
            ])
        })
    }

    /// The capsule lifts, not the strip around it.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration, highlightPreviewForItemWithIdentifier identifier: any NSCopying) -> UITargetedPreview? {
        let width = Self.barWidth(for: bounds.width)
        let capsule = CGRect(x: (bounds.width - width) / 2, y: Self.topGap, width: width, height: Self.barHeight)
        let parameters = UIPreviewParameters()
        parameters.visiblePath = UIBezierPath(roundedRect: capsule, cornerRadius: Self.barHeight / 2)
        parameters.backgroundColor = .clear
        return UITargetedPreview(view: self, parameters: parameters)
    }
}

extension EditorController {
    /// Settings › Writing Bar in a sheet over the note, from the bar's Edit button or touching and holding the bar.
    func editWritingBar() {
        guard let presenter = textView.window?.rootViewController?.topmostPresented else { return }
        let host = UIHostingController(rootView: NavigationStack {
            WritingBarSettings { [weak presenter] in presenter?.dismiss(animated: true) }
        })
        host.sheetPresentationController?.detents = [.medium(), .large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        presenter.present(host, animated: true)
    }
}

struct WritingBarView: View {
    let editor: EditorController
    @State private var page: Int? = 0

    var body: some View {
        GeometryReader { proxy in
            let width = WritingBar.barWidth(for: proxy.size.width)
            // The tools, and Edit after the last of them.
            let pages = Self.pages(of: NotebookSettings.shared.writingBarTools.filter(\.isAvailable).map(Optional.some) + [nil], width: width)
            let perPage = pages.first?.count ?? 1
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        HStack(spacing: 0) {
                            ForEach(pages[index], id: \.self) { tool in
                                if let tool { button(tool) } else { editButton }
                            }
                            // The last page keeps the others' spacing.
                            ForEach(0..<max(0, perPage - pages[index].count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                        .containerRelativeFrame(.horizontal)
                        .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $page)
            .scrollDisabled(pages.count < 2)
            .frame(width: width, height: WritingBar.barHeight)
            .overlay(alignment: .bottom) {
                if pages.count > 1 { dots(count: pages.count) }
            }
            .clipShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .frame(maxWidth: .infinity)
            .padding(.top, WritingBar.topGap)
        }
    }

    static func pages<Tool>(of tools: [Tool], width: CGFloat) -> [[Tool]] {
        let perPage = max(1, Int(width / WritingBar.toolWidth))
        return stride(from: 0, to: tools.count, by: perPage).map { Array(tools[$0..<min($0 + perPage, tools.count)]) }
    }

    /// Which page of tools this is, small at the capsule's lower edge.
    private func dots(count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(Color.primary.opacity(index == (page ?? 0) ? 0.5 : 0.15))
                    .frame(width: 4, height: 4)
            }
        }
        .padding(.bottom, 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func button(_ tool: WritingTool) -> some View {
        if tool == .attach {
            Menu {
                ForEach(AttachmentSource.available) { source in
                    Button { AttachmentPicker.shared.present(source, for: editor) } label: { Label(source.name, systemImage: source.symbol) }
                }
            } label: {
                icon(tool)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
        } else {
            Button { perform(tool) } label: { icon(tool) }
                .buttonStyle(.plain)
        }
    }

    /// Which tools the bar has and in what order, as in Settings › Writing Bar.
    private var editButton: some View {
        Button { editor.editWritingBar() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .accessibilityLabel("Edit Writing Bar")
        }
        .buttonStyle(.plain)
    }

    private func icon(_ tool: WritingTool) -> some View {
        Image(systemName: tool.symbol)
            .font(.system(size: 18))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            .accessibilityLabel(tool.name)
    }

    private func perform(_ tool: WritingTool) {
        if let command = tool.command { return editor.perform(command) }
        if let source = tool.source { return AttachmentPicker.shared.present(source, for: editor) }
        switch tool {
        case .format: editor.toggleFormatPanel()
        case .drawing: editor.beginDrawing()
        case .undo: editor.textView.undoManager?.undo()
        case .redo: editor.textView.undoManager?.redo()
        case .reminder: editor.delegate?.editorShowReminder(editor)
        default: editor.endEditing()
        }
    }
}
#endif
