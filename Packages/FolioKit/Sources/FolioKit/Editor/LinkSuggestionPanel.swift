import AppKit
import SwiftUI

@MainActor
@Observable
final class SuggestionModel {
    var items: [LinkSuggestion] = []
    var selected = 0
    var query = ""
}

/// The list that opens under `[[`: notes and files whose names match what you type, and a way to link a note that
/// doesn't exist yet. It floats next to the caret and never takes the focus from the text.
@MainActor
final class LinkSuggestionPanel {
    let model = SuggestionModel()
    var onPick: ((LinkSuggestion) -> Void)?
    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }
    var selected: LinkSuggestion? { model.items[safe: model.selected] }

    static let rowHeight: CGFloat = 34
    static let width: CGFloat = 400

    func show(_ items: [LinkSuggestion], query: String, at caret: NSRect, in window: NSWindow) {
        guard !items.isEmpty else { close(); return }
        if model.query != query || model.items != items {
            model.selected = min(model.selected, items.count - 1)
            if model.query != query { model.selected = 0 }
        }
        model.items = items
        model.query = query
        let panel = self.panel ?? makePanel()
        let height = CGFloat(items.count) * Self.rowHeight + 12 + 30
        var frame = NSRect(x: caret.minX - 18, y: caret.minY - height - 6, width: Self.width, height: height)
        if let screen = window.screen?.visibleFrame {
            if frame.minY < screen.minY { frame.origin.y = caret.maxY + 6 }
            frame.origin.x = min(max(frame.minX, screen.minX + 8), screen.maxX - frame.width - 8)
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func move(by delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.contentView = NSHostingView(rootView: SuggestionList(model: model) { [weak self] suggestion in self?.onPick?(suggestion) })
        self.panel = panel
        return panel
    }
}

private struct SuggestionList: View {
    var model: SuggestionModel
    var pick: (LinkSuggestion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(model.items.enumerated()), id: \.offset) { index, item in
                    row(item, selected: index == model.selected)
                        .contentShape(Rectangle())
                        .onTapGesture { pick(item) }
                }
            }
            .padding(.vertical, 6)
            HStack(spacing: 14) {
                hint("↑↓", "choose")
                hint("↵", "link")
                hint("esc", "keep typing")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 30)
            .overlay(alignment: .top) { Rectangle().fill(Color.theme(Theme.separator)).frame(height: 1) }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.theme(Theme.popover)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.theme(Theme.popoverBorder)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ item: LinkSuggestion, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(item))
                .font(.system(size: 13))
                .foregroundStyle(item.kind == .file ? Color.theme(Theme.textTertiary) : item.kind == .create ? Color.theme(Theme.accent) : Color.theme(Theme.textTertiary))
                .frame(width: 18)
            Text(highlighted(item))
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.theme(Theme.textTertiary))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: LinkSuggestionPanel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.theme(Theme.popoverSelected) : .clear))
        .padding(.horizontal, 5)
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
        text.foregroundColor = Color.theme(item.kind == .create ? Theme.accent : Theme.text)
        if item.kind != .create, !model.query.isEmpty, let range = text.range(of: model.query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .system(size: 13, weight: .semibold)
        }
        return text
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5))
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.theme(Theme.keycap)))
            Text(label)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color.theme(Theme.textTertiary))
    }
}

extension EditorController {
    /// Follows the text between `[[` and `]]` as you type and shows what it could link to.
    func updateSuggestions() {
        guard let anchor = suggestionAnchor else { return }
        let text = nsText
        let selection = textView.selectedRange()
        guard isFocused, selection.length == 0, anchor >= 2, anchor <= text.length,
              text.substring(with: NSRange(location: anchor - 2, length: 2)) == "[[",
              let close = closingBrackets(after: anchor),
              selection.location >= anchor, selection.location <= close else {
            closeSuggestions()
            return
        }
        let query = text.substring(with: NSRange(location: anchor, length: close - anchor))
        guard !query.contains("["), !query.contains("\n"), let window = textView.window else {
            closeSuggestions()
            return
        }
        let items = delegate?.editor(self, suggestionsFor: query) ?? []
        let caret = textView.firstRect(forCharacterRange: NSRange(location: anchor - 2, length: 0), actualRange: nil)
        suggestions.show(items, query: query, at: caret, in: window)
    }

    private func closingBrackets(after anchor: Int) -> Int? {
        let text = nsText
        var index = anchor
        while index + 1 < text.length {
            let character = text.character(at: index)
            if character == 10 { return nil }
            if character == 93, text.character(at: index + 1) == 93 { return index }
            index += 1
        }
        return nil
    }

    func closeSuggestions() {
        suggestionAnchor = nil
        suggestions.close()
    }

    func acceptSuggestion(_ suggestion: LinkSuggestion) {
        guard let anchor = suggestionAnchor, let close = closingBrackets(after: anchor) else { closeSuggestions(); return }
        let range = NSRange(location: anchor, length: close - anchor)
        closeSuggestions()
        replace(range, with: suggestion.insert, select: NSRange(location: anchor + (suggestion.insert as NSString).length + 2, length: 0), actionName: "Add Link")
    }
}
