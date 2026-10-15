import AppKit

/// A suggestion for the `[[` link popup.
public struct LinkSuggestion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case note, file, create }
    public var kind: Kind
    public var title: String
    public var detail: String
    /// What goes between the brackets.
    public var insert: String

    public init(kind: Kind, title: String, detail: String, insert: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.insert = insert
    }
}

/// What the editor needs from the app: where links go and what to do when you follow one.
@MainActor
public protocol EditorControllerDelegate: AnyObject {
    func editorTextDidChange(_ editor: EditorController)
    func editor(_ editor: EditorController, open target: LinkTarget.Kind)
    func editor(_ editor: EditorController, quickLook url: URL)
    func editor(_ editor: EditorController, commitTitle title: String)
    func editor(_ editor: EditorController, suggestionsFor query: String) -> [LinkSuggestion]
    func editor(_ editor: EditorController, resolve target: String) -> URL?
    /// The note's name, used to name pictures pasted into it.
    func editorNoteName(_ editor: EditorController) -> String
    /// The headings or the word count changed.
    func editorOutlineDidChange(_ editor: EditorController)
    /// You scrolled: into another section, or the title out of view.
    func editorPositionDidChange(_ editor: EditorController)
}

public extension EditorControllerDelegate {
    func editorOutlineDidChange(_ editor: EditorController) {}
    func editorPositionDidChange(_ editor: EditorController) {}
}

/// Folio's editor: a TextKit 1 text view whose storage holds the note's Markdown exactly, styled so that it reads as
/// a finished document. Markdown punctuation shows only right next to a resting caret; while you select, nothing moves.
@MainActor
public final class EditorController: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate, NSTextFieldDelegate, EditorLayoutSource {
    public weak var delegate: EditorControllerDelegate?

    let storage = NSTextStorage()
    let layoutManager = FolioLayoutManager()
    let container = NSTextContainer(size: NSSize(width: EditorStyle.contentWidth, height: CGFloat.greatestFiniteMagnitude))
    let textView: MarkdownTextView
    public let scrollView = NSScrollView()

    private(set) var document = MarkdownParser.parse("")
    private var lineSignatures: [Int] = []
    /// Character ranges whose hidden punctuation is shown, because the caret is in or next to them.
    private(set) var revealed: [NSRange] = []
    /// The block the caret is in, if it shows its Markdown then (tables, math, diagrams, frontmatter).
    private(set) var activeBlock: Int?
    private var isLoading = false
    private var isApplyingStyle = false
    /// True while the editor changes the text itself, so its own changes aren't taken for typing.
    var isPerformingEdit = false
    /// The folder of the note, which pictures and relative links start from.
    public private(set) var folder: URL?

    let suggestions = LinkSuggestionPanel()

    /// The note's headings, for the outline next to it.
    public internal(set) var outline: [OutlineHeading] = []
    public internal(set) var stats = NoteStats()
    /// The heading whose section is at the top of the window, as an index into `outline`.
    public internal(set) var currentHeading: Int?
    /// True once the title has scrolled up under the toolbar.
    public internal(set) var isTitleScrolledAway = false
    var outlineUpdate: DispatchWorkItem?
    /// The heading picked in the outline and where that scrolled to: it stays the current one until you scroll away,
    /// even when the note ends too soon to bring it to the top.
    var jump: (heading: Int?, y: CGFloat)?
    var isJumping = false
    /// Where the `[[` the popup completes starts (just after the brackets). While it is set, that link is drawn as
    /// the text being typed rather than as a finished link.
    var suggestionAnchor: Int? {
        didSet {
            guard oldValue != suggestionAnchor, !isLoading else { return }
            let lines = [oldValue, suggestionAnchor].compactMap { $0 }.filter { $0 <= storage.length }.map { document.lineIndex(containing: $0) }
            restyle(lines: Array(Set(lines)))
        }
    }

    public override init() {
        _ = FolioSettings.shared
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: nil)
        super.init()
        storage.addLayoutManager(layoutManager)
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        textView.replaceTextContainer(container)
        configureTextView()
        storage.delegate = self
        layoutManager.source = self
        textView.controller = self
        textView.delegate = self
        textView.titleField.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        // Room for the toolbar, which the note scrolls under.
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(typographyChanged), name: .folioTypographyChanged, object: nil)
        suggestions.onPick = { [weak self] suggestion in self?.acceptSuggestion(suggestion) }
    }

    private func configureTextView() {
        let view = textView
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.drawsBackground = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.insertionPointColor = Theme.accent
        // The system's selection colour, without changing the colour of the text.
        view.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        view.linkTextAttributes = [:]
        view.typingAttributes = MarkdownStyler.baseAttributes
        view.defaultParagraphStyle = EditorStyle.paragraph()
        view.textContainerInset = NSSize(width: 60, height: MarkdownTextView.headerHeight)
        view.setAccessibilityLabel("Note")
    }

    public var view: NSView { scrollView }
    public var text: String { storage.string }
    var nsText: NSString { storage.string as NSString }

    // MARK: - Loading

    /// Shows a note. `title` is its name; `focusTitle` puts the caret in the title (for a new note).
    public func load(text: String, folder: URL?, title: String, meta: String, focusTitle: Bool = false) {
        isLoading = true
        self.folder = folder
        closeSuggestions()
        jump = nil
        revealed = []
        activeBlock = nil
        lineSignatures = []
        textView.titleField.stringValue = title
        textView.metaLabel.stringValue = meta
        updateLayoutMode(for: (text as NSString).length)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        isLoading = false
        scrollToTop()
        updateOutline()
        if focusTitle {
            textView.window?.makeFirstResponder(textView.titleField)
        }
    }

    /// Takes in a new version of the text from disk (changed elsewhere, or merged with it). Only the part that
    /// differs is replaced, as an edit that can be undone, so the caret and the scroll position stay where they are.
    public func reload(text: String) {
        let old = storage.string as NSString
        let new = text as NSString
        guard old as String != text else { return }
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
        let selection = textView.selectedRange()
        let delta = (replacement as NSString).length - range.length
        var caret = selection
        if selection.location >= range.upperBound { caret.location += delta } else if selection.location > range.location { caret = NSRange(location: range.location + (replacement as NSString).length, length: 0) }
        preservingScroll {
            replace(range, with: replacement, select: caret, actionName: "Change from Another Device")
        }
    }

    /// Notes up to a few thousand words are laid out whole, so nothing below the window ever changes size by
    /// surprise. Longer ones are laid out where you look, so every keystroke stays within a frame.
    static let wholeLayoutLimit = 20_000

    private func updateLayoutMode(for length: Int) {
        let partial = length > Self.wholeLayoutLimit
        if layoutManager.allowsNonContiguousLayout != partial { layoutManager.allowsNonContiguousLayout = partial }
    }

    public func setMeta(_ meta: String) { textView.metaLabel.stringValue = meta }
    public func setTitle(_ title: String) {
        if textView.window?.firstResponder !== textView.titleField.currentEditor() { textView.titleField.stringValue = title }
    }

    public func focusText(atEnd: Bool = false) {
        textView.window?.makeFirstResponder(textView)
        let location = atEnd ? storage.length : 0
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    public func focusTitle() {
        textView.window?.makeFirstResponder(textView.titleField)
    }

    /// Links and pictures may point somewhere else now (files were added, renamed, deleted): style them again.
    public func refreshLinks() {
        let lines = document.lines.indices.filter { index in
            document.lines[index].spans.contains { span in
                switch span.kind {
                case .wikiLink, .embed, .image: true
                default: false
                }
            }
        }
        guard !lines.isEmpty else { return }
        restyle(lines: lines)
    }

    // MARK: - Parsing and styling

    var environment: StyleEnvironment {
        StyleEnvironment(
            folder: folder,
            resolve: { [weak self] target in self.flatMap { $0.delegate?.editor($0, resolve: target) } },
            activeBlock: activeBlock,
            composing: suggestionAnchor,
            previewHeight: { [weak self] block in self?.previewHeight(for: block) ?? 0 }
        )
    }

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isApplyingStyle else { return }
        updateLayoutMode(for: textStorage.length)
        if !isLoading { scheduleOutlineUpdate() }
        let oldDocument = document
        let oldSignatures = lineSignatures
        document = MarkdownParser.parse(storage.mutableString)
        // Keep the revealed punctuation where it was until the caret settles, moved along with the edit.
        let oldEnd = editedRange.location + editedRange.length - delta
        revealed = revealed.compactMap { range in
            if range.upperBound <= editedRange.location { return range }
            if range.location >= oldEnd { return range.shifted(by: delta) }
            let start = min(range.location, editedRange.location)
            let end = min(storage.length, max(range.upperBound + delta, editedRange.upperBound))
            return end > start ? NSRange(location: start, length: end - start) : nil
        }
        // The open block is the one being typed in, wherever its index moved to.
        if activeBlock != nil {
            let caret = min(editedRange.upperBound, storage.length)
            let line = document.lineIndex(containing: caret)
            if let block = document.lines[safe: line]?.block, document.blocks[block].isSwappable { activeBlock = block } else { activeBlock = nil }
        }

        let signatures = computeSignatures()
        var lines: [Int] = []
        let lineDelta = document.lines.count - oldDocument.lines.count
        for index in document.lines.indices {
            let line = document.lines[index]
            var oldIndex: Int?
            if line.fullRange.upperBound <= editedRange.location {
                oldIndex = index
            } else if line.range.location >= editedRange.upperBound {
                oldIndex = index - lineDelta
            }
            if let oldIndex, oldIndex >= 0, oldIndex < oldSignatures.count, oldSignatures[oldIndex] == signatures[index] { continue }
            lines.append(index)
        }
        lineSignatures = signatures
        isApplyingStyle = true
        MarkdownStyler.style(storage, document: document, lines: lines, environment: environment)
        isApplyingStyle = false
    }


    /// What decides how a line looks: its text, what kind of line it is, the block it is in and whether that block is
    /// being edited. Lines whose signature didn't change keep their attributes.
    private func computeSignatures() -> [Int] {
        var blockHashes: [Int] = []
        for (index, block) in document.blocks.enumerated() {
            var hasher = Hasher()
            for line in block.lines { hasher.combine(document.lines[line].textHash) }
            hasher.combine(index == activeBlock)
            hasher.combine(block.kind)
            blockHashes.append(hasher.finalize())
        }
        return document.lines.enumerated().map { index, line in
            var hasher = Hasher()
            hasher.combine(line.textHash)
            Self.combineShape(of: line, into: &hasher)
            if let block = line.block {
                hasher.combine(blockHashes[block])
                hasher.combine(index - document.blocks[block].lines.lowerBound)
            }
            hasher.combine(index == 0)
            return hasher.finalize()
        }
    }

    /// A line's kind without where it is in the note, so lines that only moved don't count as changed.
    private static func combineShape(of line: MarkdownLine, into hasher: inout Hasher) {
        let start = line.range.location
        func relative(_ range: NSRange) -> Int { (range.location - start) << 16 | range.length }
        switch line.kind {
        case .heading(let level, let marker):
            hasher.combine(1); hasher.combine(level); hasher.combine(relative(marker))
        case .listItem(let item):
            hasher.combine(2); hasher.combine(item.indent); hasher.combine(item.level); hasher.combine(item.marker)
            hasher.combine(relative(item.markerRange)); hasher.combine(relative(item.prefix)); hasher.combine(item.checked)
            hasher.combine(item.checkbox.map(relative) ?? -1)
        case .quote(let depth, let prefix):
            hasher.combine(3); hasher.combine(depth); hasher.combine(relative(prefix))
        case .footnoteDefinition(let label):
            hasher.combine(4); hasher.combine(relative(label))
        case .blank: hasher.combine(10)
        case .paragraph: hasher.combine(11)
        case .thematicBreak: hasher.combine(12)
        case .fence: hasher.combine(13)
        case .code: hasher.combine(14)
        case .mathDelimiter: hasher.combine(15)
        case .math: hasher.combine(16)
        case .tableHeader: hasher.combine(17)
        case .tableDelimiter: hasher.combine(18)
        case .tableRow: hasher.combine(19)
        case .frontmatterDelimiter: hasher.combine(20)
        case .frontmatter: hasher.combine(21)
        }
    }

    /// Styles lines again outside of an edit (the caret entered a block, a link's target appeared).
    func restyle(lines: [Int]) {
        guard !lines.isEmpty else { return }
        isApplyingStyle = true
        storage.beginEditing()
        MarkdownStyler.style(storage, document: document, lines: lines, environment: environment)
        storage.endEditing()
        isApplyingStyle = false
        lineSignatures = computeSignatures()
    }

    /// The typeface, size, spacing or width changed in the settings: the whole note is set again, keeping the line
    /// you are on where it is.
    @objc func typographyChanged() {
        textView.typingAttributes = MarkdownStyler.baseAttributes
        textView.defaultParagraphStyle = EditorStyle.paragraph()
        textView.applyTypography()
        preservingScroll {
            restyle(lines: Array(document.lines.indices))
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }

    func lines(of block: Int) -> [Int] {
        guard let block = document.blocks[safe: block] else { return [] }
        return Array(block.lines)
    }

    private func previewHeight(for block: MarkdownBlock) -> CGFloat {
        let width = container.size.width
        switch block.kind {
        case .mermaid:
            let source = MarkdownStyler.diagramSource(nsText, document, block)
            if case .some(.some(let image)) = DiagramStore.diagram(source, isDark: isDarkAppearance, ready: { [weak self] in
                guard let self, let index = self.document.blocks.firstIndex(where: { $0.range == block.range }) else { return }
                self.preservingScroll { self.restyle(lines: self.lines(of: index)) }
            }) {
                let scale = image.size.width > width ? width / image.size.width : 1
                return ceil(image.size.height * scale)
            }
            return 80
        case .math:
            let tex = MarkdownStyler.mathSource(nsText, document, block)
            if let math = MathStore.render(tex, display: true, size: 19, color: Theme.text.resolved(dark: isDarkAppearance)) {
                return ceil(math.image.size.height)
            }
            return 30
        default:
            return 0
        }
    }

    // MARK: - Revealing Markdown next to the caret

    var isFocused: Bool {
        textView.window?.firstResponder === textView
    }

    /// The punctuation to show and the block to open for the caret where it is: none while text is selected or the
    /// note doesn't have the focus.
    func revealTarget() -> (ranges: [NSRange], block: Int?) {
        let selection = textView.selectedRange()
        guard isFocused, !document.lines.isEmpty else { return ([], nil) }
        // While text is selected nothing appears or disappears, so the selection never moves under the pointer:
        // what showed next to the caret before stays until the caret rests somewhere again.
        if selection.length > 0 { return (revealed, activeBlock) }
        let caret = selection.location
        let lineIndex = document.lineIndex(containing: caret)
        let line = document.lines[lineIndex]
        var ranges: [NSRange] = []
        var block: Int?
        if let index = line.block {
            let found = document.blocks[index]
            if found.isSwappable { block = index }
            if case .code = found.kind { ranges.append(found.range) }
            if case .callout = found.kind, lineIndex == found.lines.lowerBound { ranges.append(line.range) }
        }
        switch line.kind {
        case .heading(_, let marker): ranges.append(marker)
        case .thematicBreak: ranges.append(line.range)
        default: break
        }
        for span in line.spans where !isAtomic(span) && span.range.touches(caret) {
            ranges.append(span.range)
        }
        return (merged(ranges), block)
    }

    private func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var result: [NSRange] = []
        for range in sorted {
            if let last = result.last, range.location <= last.upperBound {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    func isRevealed(_ characterIndex: Int) -> Bool {
        var low = 0, high = revealed.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = revealed[mid]
            if characterIndex < range.location { high = mid - 1 } else if characterIndex >= range.upperBound { low = mid + 1 } else { return true }
        }
        return false
    }

    /// Shows the punctuation next to the caret and opens the block it is in, keeping the caret's line still on screen.
    func updateReveal(anchor: Int? = nil) {
        guard !isLoading, !textView.isTrackingMouse else { return }
        let target = revealTarget()
        guard target.ranges != revealed || target.block != activeBlock else { return }
        preservingScroll(anchor: anchor) {
            let old = revealed
            revealed = target.ranges
            if target.block != activeBlock {
                let previous = activeBlock
                activeBlock = target.block
                var lines: [Int] = []
                if let previous { lines += self.lines(of: previous) }
                if let block = target.block { lines += self.lines(of: block) }
                restyle(lines: lines)
            }
            for range in old + target.ranges where range.upperBound <= storage.length {
                let lineRange = nsText.lineRange(for: range)
                layoutManager.invalidateGlyphs(forCharacterRange: lineRange, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: lineRange, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: lineRange)
            }
        }
        // A heading's level tag is drawn in the margin, outside the text the layout manager invalidates.
        textView.needsDisplay = true
    }

    /// Runs a change that may make lines taller or shorter and scrolls so that the caret (or the top line, when the
    /// caret is off screen) stays exactly where it was on screen.
    func preservingScroll(anchor: Int? = nil, _ change: () -> Void) {
        let clip = scrollView.contentView
        guard textView.window != nil, storage.length > 0 else { change(); return }
        let visible = clip.bounds
        let selection = textView.selectedRange()
        var index = anchor ?? selection.location
        var y = yPosition(of: index)
        if anchor == nil, y < visible.minY + scrollView.contentInsets.top || y > visible.maxY {
            index = firstVisibleCharacter()
            y = yPosition(of: index)
        }
        let before = y - visible.minY
        change()
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, index + 1)))
        let after = yPosition(of: index) - visible.minY
        let delta = after - before
        if abs(delta) > 0.5 {
            clip.scroll(to: NSPoint(x: visible.minX, y: max(-scrollView.contentInsets.top, visible.minY + delta)))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func yPosition(of index: Int) -> CGFloat {
        guard storage.length > 0 else { return 0 }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, storage.length - 1))
        guard glyph < layoutManager.numberOfGlyphs else { return 0 }
        if index >= storage.length, layoutManager.extraLineFragmentTextContainer != nil {
            return layoutManager.extraLineFragmentRect.minY + textView.textContainerOrigin.y
        }
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textView.textContainerOrigin.y
    }

    private func firstVisibleCharacter() -> Int {
        let visible = scrollView.contentView.bounds
        let point = NSPoint(x: visible.minX + 1, y: max(0, visible.minY + scrollView.contentInsets.top - textView.textContainerOrigin.y + 1))
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    // MARK: - EditorLayoutSource

    var isDarkAppearance: Bool {
        textView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func objectNeedsDisplay(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        layoutManager.invalidateDisplay(forCharacterRange: range)
    }

    func objectNeedsLayout(_ range: NSRange) {
        guard range.upperBound <= storage.length else { return }
        preservingScroll {
            layoutManager.invalidateLayout(forCharacterRange: nsText.lineRange(for: range), actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: nsText.lineRange(for: range))
        }
    }

    func noteText(for url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - NSTextViewDelegate

    public func textViewDidChangeSelection(_ notification: Notification) {
        layoutManager.selectedRanges = textView.selectedRanges.map(\.rangeValue)
        if !textView.isTrackingMouse { updateReveal() }
        updateSuggestions()
        textView.needsDisplay = true
    }

    public func textDidChange(_ notification: Notification) {
        guard !isLoading else { return }
        delegate?.editorTextDidChange(self)
        updateSuggestions()
    }

    func mouseTrackingEnded() {
        layoutManager.selectedRanges = textView.selectedRanges.map(\.rangeValue)
        updateReveal()
    }

    func focusChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.updateReveal()
            if self?.isFocused == false { self?.closeSuggestions() }
        }
    }

    public func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue], toCharacterRanges newSelectedCharRanges: [NSValue]) -> [NSValue] {
        guard !isLoading, newSelectedCharRanges.count == 1, let old = oldSelectedCharRanges.first?.rangeValue else { return newSelectedCharRanges }
        let range = newSelectedCharRanges[0].rangeValue
        if range.length == 0 {
            return [NSValue(range: NSRange(location: snapCaret(range.location, from: old), length: 0))]
        }
        return [NSValue(range: expandSelection(range))]
    }

    /// No spelling marks in code, math, links, addresses or hidden Markdown: they aren't prose.
    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
        guard value != 0, affectedCharRange.upperBound <= storage.length, !document.lines.isEmpty else { return value }
        for index in affectedCharRange.location..<affectedCharRange.upperBound {
            if layoutManager.isHidden(index) || layoutManager.object(at: index) != nil { return 0 }
            if let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont, font.isFixedPitch { return 0 }
        }
        let line = document.lines[document.lineIndex(containing: affectedCharRange.location)]
        for span in line.spans where NSIntersectionRange(span.range, affectedCharRange).length > 0 {
            switch span.kind {
            case .code, .math, .link, .autolink, .wikiLink, .embed, .image: return 0
            default: break
            }
        }
        if case .code = line.kind { return 0 }
        return value
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        handleCommand(commandSelector)
    }

    public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isLoading, let replacement = replacementString else { return true }
        return shouldInsert(replacement, in: affectedCharRange)
    }

    // MARK: - Title

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === self.textView.titleField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveDown(_:)):
            commitTitle()
            focusText()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return false
        default:
            return false
        }
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === textView.titleField else { return }
        commitTitle()
    }

    private func commitTitle() {
        let title = textView.titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        delegate?.editor(self, commitTitle: title)
    }

    // MARK: - Caret

    /// The caret drawn from the baseline up to the top of the text, rather than over the whole line.
    func caretRect(proposed rect: NSRect) -> NSRect {
        let selection = textView.selectedRange()
        guard selection.length == 0, storage.length > 0 else { return shortCaret(rect, font: EditorStyle.body) }
        let index = selection.location
        let fontIndex = index > 0 && (index >= storage.length || nsText.character(at: index) == 10) ? index - 1 : min(index, storage.length - 1)
        var font = (storage.attribute(.font, at: max(0, fontIndex), effectiveRange: nil) as? NSFont) ?? EditorStyle.body
        if font.pointSize < 4 { font = EditorStyle.body }
        guard index < storage.length else { return shortCaret(rect, font: font) }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        guard glyph < layoutManager.numberOfGlyphs else { return shortCaret(rect, font: font) }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        let offset = (storage.attribute(.baselineOffset, at: index, effectiveRange: nil) as? CGFloat) ?? 0
        let baseline = textView.textContainerOrigin.y + line.minY + location.y - offset
        let top = baseline - font.ascender - 1
        let height = font.ascender - font.descender + 2
        guard abs(rect.midY - (top + height / 2)) < line.height else { return shortCaret(rect, font: font) }
        return NSRect(x: rect.minX, y: top, width: rect.width, height: height)
    }

    private func shortCaret(_ rect: NSRect, font: NSFont) -> NSRect {
        let height = min(rect.height, font.ascender - font.descender + 2)
        return NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}
