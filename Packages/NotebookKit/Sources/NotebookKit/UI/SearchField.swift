import AppKit
import SwiftUI

/// What a search suggestion opens.
enum SearchResult: Hashable {
    case file(URL)
    case newNote(String)
}

/// The search field in the toolbar: the system's search field with the system's suggestions menu below it. It finds
/// files by name, then text in notes and PDFs; ⌘F puts the caret in it, arrow keys and Return pick a result.
@MainActor
final class SearchController: NSObject, NSTextSuggestionsDelegate, NSSearchFieldDelegate {
    typealias SuggestionItemType = SearchResult

    let field = ToolbarSearchField()
    private unowned let workspace: Workspace

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init()
        field.placeholderString = "Search"
        // The toolbar's glass capsule is the field's shape.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = self
        field.suggestionsDelegate = self
        field.setAccessibilityLabel("Search notes and files")
    }

    /// ⌘F, also from a note in a window of its own.
    func focus() {
        guard let window = field.window else { return }
        if NSApp.isActive, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: - Suggestions

    func textField(_ textField: NSTextField, provideUpdatedSuggestions responseHandler: @escaping (ItemResponse) -> Void) {
        var response = ItemResponse(itemSections: sections(for: textField.stringValue))
        response.preferredHighlight = .firstSelectableItem
        responseHandler(response)
    }

    func textField(_ textField: NSTextField, textCompletionFor item: Item) -> String? {
        // The field keeps what you typed while you move through the results.
        nil
    }

    func textField(_ textField: NSTextField, didSelect item: Item) {
        run(item.representedValue)
    }

    func sections(for text: String) -> [ItemSection] {
        let query = text.trimmingCharacters(in: .whitespaces)
        let index = workspace.index
        guard !query.isEmpty else {
            let recent = workspace.recentURLs.prefix(6).map { url in
                item(.file(url), title: displayName(url), detail: index.entry(for: url)?.place, kind: FileKind(url: url, isDirectory: false))
            }
            return recent.isEmpty ? [] : [ItemSection(title: "Recent", items: Array(recent))]
        }
        var sections: [ItemSection] = []
        let files = index.files(matching: query, limit: 6)
        if !files.isEmpty {
            sections.append(ItemSection(title: "Files", items: files.map { entry in
                item(.file(entry.url), title: entry.name, detail: entry.place, kind: entry.kind, inCloud: entry.isInCloud)
            }))
        }
        let named = Set(files.map(\.url))
        let hits = index.textHits(query, limit: 6).filter { !named.contains($0.entry.url) }
        if !hits.isEmpty {
            sections.append(ItemSection(title: "In Notes and PDFs", items: hits.map { hit in
                var result = item(.file(hit.entry.url), title: hit.entry.kind == .note ? hit.entry.name : hit.entry.url.lastPathComponent,
                                  detail: nil, kind: hit.entry.kind)
                if let page = hit.page { result.title += " – page \(page)" }
                // The words you searched for in bold.
                let snippet = NSMutableAttributedString(string: hit.snippet)
                if let match = hit.match {
                    snippet.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), range: NSRange(match, in: hit.snippet))
                }
                result.attributedSecondaryTitle = try? AttributedString(snippet, including: \.appKit)
                result.toolTip = hit.entry.place
                return result
            }))
        }
        var create = NSSuggestionItem(representedValue: SearchResult.newNote(query), title: "New Note “\(query)”")
        create.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        sections.append(ItemSection(items: [create]))
        return sections
    }

    private func item(_ result: SearchResult, title: String, detail: String?, kind: FileKind, inCloud: Bool = false) -> Item {
        var item = NSSuggestionItem(representedValue: result, title: title)
        item.secondaryTitle = detail
        let symbol = inCloud ? "icloud.and.arrow.down" : kind.symbol
        let tint: NSColor = kind == .folder ? .controlAccentColor : kind == .note || kind == .other ? .secondaryLabelColor : kind.tint
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        return item
    }

    private func displayName(_ url: URL) -> String {
        FileKind(url: url, isDirectory: false) == .note ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    // MARK: - Picking

    func run(_ result: SearchResult) {
        switch result {
        case .file(let url):
            workspace.open(url)
        case .newNote(let title):
            workspace.newNote(title: title)
        }
        leave()
    }

    /// Done searching: the field empties and the caret goes to the note, or out of the field when a PDF or
    /// picture is open, so you type into what you picked.
    private func leave() {
        field.stringValue = ""
        field.window?.makeFirstResponder(workspace.note != nil ? workspace.editor.textView : nil)
    }

    /// Return with no result chosen opens the best one, as the first suggestion would.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           let first = sections(for: field.stringValue).first(where: { !$0.items.isEmpty })?.items.first {
            run(first.representedValue)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            leave()
            return true
        }
        return false
    }
}

/// A search field without a bezel of its own, for the toolbar's glass capsule, laid out as a bezeled one.
final class ToolbarSearchField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { ToolbarSearchFieldCell.self }
        set {}
    }
}

/// Without a bezel the system's cell puts the text you type over the magnifying glass, and draws its text at the top
/// of a field taller than one line. This one keeps the glass, the text and the clear button where a bezeled field
/// has them, while you type too, centred in the capsule.
final class ToolbarSearchFieldCell: NSSearchFieldCell {
    override func searchButtonRect(forBounds rect: NSRect) -> NSRect { super.searchButtonRect(forBounds: line(in: rect)) }
    override func searchTextRect(forBounds rect: NSRect) -> NSRect { super.searchTextRect(forBounds: line(in: rect)) }
    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect { super.cancelButtonRect(forBounds: line(in: rect)) }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { line(in: super.drawingRect(forBounds: rect)) }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: searchTextRect(forBounds: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    /// One line of text, centred in the field.
    private func line(in rect: NSRect) -> NSRect {
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let height = min(rect.height, (font.ascender - font.descender + font.leading).rounded(.up))
        return NSRect(x: rect.minX, y: rect.minY + ((rect.height - height) / 2).rounded(), width: rect.width, height: height)
    }
}

/// The search field as a toolbar item.
struct SearchFieldItem: NSViewRepresentable {
    let controller: SearchController

    func makeNSView(context: Context) -> NSSearchField { controller.field }
    func updateNSView(_ field: NSSearchField, context: Context) {}

    /// The whole size it is given, not one line: a click anywhere in the capsule goes to the field.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 190, height: proposal.height ?? nsView.intrinsicContentSize.height)
    }
}
