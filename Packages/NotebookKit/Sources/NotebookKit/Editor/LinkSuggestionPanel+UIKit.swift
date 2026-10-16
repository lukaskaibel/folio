#if os(iOS)
import SwiftUI
import UIKit

/// The list that opens under `[[` on iPhone and iPad: a card under the line you are typing on, or above it when the
/// keyboard would cover it, with the notes and files whose names match. A tap picks one, and the keyboard stays.
@MainActor
final class LinkSuggestionPanel {
    let model = SuggestionModel()
    var onPick: ((LinkSuggestion) -> Void)?
    private var host: UIHostingController<SuggestionCard>?

    var isVisible: Bool { host.map { $0.view.superview != nil && !$0.view.isHidden } ?? false }
    var selected: LinkSuggestion? { model.items[safe: model.selected] }

    static let rowHeight: CGFloat = 44
    static let visibleRows = 5

    /// `caret` and `visible` are in the coordinates of `view`, the text view the card scrolls with.
    func show(_ items: [LinkSuggestion], query: String, below caret: CGRect, within visible: CGRect, in view: UIView) {
        guard !items.isEmpty else { close(); return }
        model.update(items, query: query)
        let host = self.host ?? make()
        let width = min(380, view.bounds.width - 24)
        let height = CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight + 12
        var frame = CGRect(x: caret.minX - 18, y: caret.maxY + 6, width: width, height: height)
        if frame.maxY > visible.maxY, caret.minY - height - 6 >= visible.minY { frame.origin.y = caret.minY - height - 6 }
        frame.origin.x = min(max(frame.minX, 12), view.bounds.width - width - 12)
        if host.view.superview !== view { view.addSubview(host.view) }
        let appearing = host.view.isHidden || host.view.superview == nil
        host.view.frame = frame
        host.view.isHidden = false
        if appearing {
            host.view.alpha = 0
            host.view.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                host.view.alpha = 1
                host.view.transform = .identity
            }
        }
    }

    func move(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    func close() {
        guard let host, !host.view.isHidden else { return }
        host.view.isHidden = true
    }

    private func make() -> UIHostingController<SuggestionCard> {
        let host = UIHostingController(rootView: SuggestionCard(model: model) { [weak self] suggestion in self?.onPick?(suggestion) })
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        self.host = host
        return host
    }
}

/// The card: a row per suggestion, the one picked with the arrow keys of a keyboard tinted.
struct SuggestionCard: View {
    var model: SuggestionModel
    var pick: (LinkSuggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                        Button { pick(item) } label: { row(item, selected: index == model.selected) }
                            .buttonStyle(.plain)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: model.selected) { _, selected in proxy.scrollTo(selected) }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    private func row(_ item: LinkSuggestion, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(item))
                .font(.system(size: 15))
                .foregroundStyle(item.kind == .create ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            Text(highlighted(item))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: LinkSuggestionPanel.rowHeight)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
    }

    private func icon(_ item: LinkSuggestion) -> String {
        switch item.kind {
        case .note: "doc.text"
        case .file: "doc"
        case .create: "plus"
        }
    }

    /// The name with the part you typed in bold.
    private func highlighted(_ item: LinkSuggestion) -> AttributedString {
        var text = AttributedString(item.title)
        text.foregroundColor = item.kind == .create ? .accentColor : .primary
        if item.kind != .create, !model.query.isEmpty, let range = text.range(of: model.query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .body.weight(.semibold)
        }
        return text
    }
}
#endif
