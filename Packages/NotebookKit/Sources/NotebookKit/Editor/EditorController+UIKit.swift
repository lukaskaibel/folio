#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// The editor in a UIKit text view: taps instead of clicks, the keyboard's Return and Backspace as text, the keyboard
/// over the note, and a menu instead of a popover.
extension EditorController: UITextViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate, UITextDropDelegate {
    func configureTextView() {
        let view = textView
        view.isEditable = true
        view.isSelectable = true
        view.allowsEditingTextAttributes = false
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocorrectionType = .default
        view.spellCheckingType = .default
        view.dataDetectorTypes = []
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.contentInsetAdjustmentBehavior = .always
        view.isFindInteractionEnabled = true
        view.tintColor = Theme.accent
        view.typingAttributes = MarkdownStyler.baseAttributes
        view.linkTextAttributes = [:]
        view.accessibilityLabel = "Note"
        view.delegate = self
        view.titleField.delegate = self
        view.titleField.addTarget(self, action: #selector(titleReturn), for: .editingDidEndOnExit)
        view.inputAccessoryView = WritingBar(editor: self)
        // The title is plain text: none of the writing bar's formatting goes there. Without a bar of its own, it
        // would show the text view's, which it is inside of.
        view.titleField.inputAccessoryView = UIView(frame: .zero)

        view.textDropDelegate = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// The note's view: the text view, which scrolls itself.
    public var view: UIView { textView }

    // MARK: - What the shared editor asks of the text view

    var selection: NSRange { textView.selectedRange }

    func setSelection(_ range: NSRange) {
        isSettingSelection = true
        textView.selectedRange = range
        isSettingSelection = false
    }

    var selectedRanges: [NSRange] { [textView.selectedRange] }
    var isFocused: Bool { textView.isFirstResponder }

    /// A finger is placing the caret or dragging a selection's handles: nothing is revealed or hidden until it
    /// lifts, so the text never moves under it. Scrolling doesn't count.
    var isTracking: Bool {
        func active(_ view: UIView) -> Bool {
            (view.gestureRecognizers ?? []).contains { recognizer in
                recognizer !== textView.panGestureRecognizer && recognizer !== textView.pinchGestureRecognizer
                    && (recognizer.state == .began || recognizer.state == .changed)
            }
        }
        return active(textView) || textView.subviews.contains(where: active)
    }

    var isInWindow: Bool { textView.window != nil }
    var textOrigin: CGPoint { textView.textContainerOrigin }

    /// The top of the visible part of the text view, which is under the navigation bar.
    var scrollTop: CGFloat { textView.contentOffset.y }
    /// The room the navigation bar takes at the top.
    var topInset: CGFloat { textView.adjustedContentInset.top }
    var visibleRect: CGRect { textView.bounds }
    /// From the layout rather than the content size, which UIKit updates only when it next lays the view out:
    /// right after a note is loaded it is still the last note's.
    var maxScrollTop: CGFloat {
        let height = layoutManager.usedRect(for: container).maxY + textView.textContainerInset.top + textView.textContainerInset.bottom
        return max(-topInset, height + textView.adjustedContentInset.bottom - textView.bounds.height)
    }

    func setScrollTop(_ y: CGFloat) {
        textView.contentOffset = CGPoint(x: -textView.adjustedContentInset.left, y: y)
    }

    func animateScrollTop(to y: CGFloat, completion: @escaping @MainActor () -> Void) {
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.setScrollTop(y)
        } completion: { _ in
            completion()
        }
    }

    var titleText: String {
        get { textView.titleField.text ?? "" }
        set { textView.titleField.text = newValue }
    }

    var isEditingTitle: Bool { textView.titleField.isFirstResponder }
    var titleFrame: CGRect { textView.titleField.frame }

    var metaText: String {
        get { textView.metaLabel.text ?? "" }
        set { textView.metaLabel.text = newValue }
    }

    /// The keyboard comes up for the text, or for the title, once the note is on screen if it isn't yet: a new
    /// note is made before its screen slides in.
    func makeTextFirstResponder() {
        requestedFocus = (.text, Date())
        pendingFocus = nil
        if textView.window == nil { pendingFocus = .text } else { _ = textView.becomeFirstResponder() }
    }

    func makeTitleFirstResponder() {
        requestedFocus = (.title, Date())
        pendingFocus = nil
        if textView.window == nil { pendingFocus = .title } else { _ = textView.titleField.becomeFirstResponder() }
    }

    /// The editor is about to move to another screen: leaving the window takes the keyboard away, and with it
    /// comes back on the new screen.
    func beginMove() {
        isMoving = true
        // What was asked for a moment ago counts over what has the focus now: as the old screen slides away, UIKit
        // hands the title's focus to the text view it is in.
        if let (focus, date) = requestedFocus, Date().timeIntervalSince(date) < 1.5 {
            pendingFocus = focus
        } else if textView.titleField.isFirstResponder {
            pendingFocus = .title
        } else if textView.isFirstResponder {
            pendingFocus = .text
        }
    }

    func endMove() {
        isMoving = false
        focusWhenShown()
    }

    /// No screen took the editor (you went back to a folder): the keyboard stays away.
    func finishMoveIfNowhere() {
        guard isMoving, textView.window == nil else { return }
        isMoving = false
        pendingFocus = nil
        delegate?.editorEditingDidChange(self)
    }

    func focusWhenShown() {
        guard let focus = pendingFocus, textView.window != nil else { return }
        pendingFocus = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = focus == .title ? self.textView.titleField.becomeFirstResponder() : self.textView.becomeFirstResponder()
        }
    }

    var isDarkAppearance: Bool { textView.traitCollection.userInterfaceStyle == .dark }

    /// Selected pictures and tables draw a ring of their own, in the text.
    func textNeedsDisplay() {
        let glyphs = layoutManager.glyphRange(forBoundingRect: textView.bounds.offsetBy(dx: -textOrigin.x, dy: -textOrigin.y), in: container)
        layoutManager.invalidateDisplay(forGlyphRange: glyphs)
    }

    /// The heading level in the margin: shown next to the heading the caret is on, where there is room for it.
    func marginNeedsDisplay() {
        let button = textView.headingButton
        guard textView.sideMargin >= 44, let (level, marker) = headingMarkLevel,
              let rect = layoutManager.headingMarkRect(at: marker.location, origin: textOrigin) else {
            button.isHidden = true
            return
        }
        button.frame = rect.insetBy(dx: -6, dy: -8)
        var configuration = button.configuration ?? .plain()
        configuration.attributedTitle = AttributedString("H\(level)", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: Theme.textTertiary]))
        configuration.background.backgroundColor = Theme.control
        configuration.background.cornerRadius = 5
        configuration.background.backgroundInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.menu = headingMenu(current: level)
        button.isHidden = false
    }

    /// Title, Heading, Subheading or Body, for the heading the caret is on.
    private func headingMenu(current: Int) -> UIMenu {
        let styles: [(String, LineFormat, Int)] = [("Title", .heading(1), 1), ("Heading", .heading(2), 2), ("Subheading", .heading(3), 3), ("Body", .body, 0)]
        return UIMenu(children: styles.map { title, format, level in
            UIAction(title: title, state: level == current ? .on : .off) { [weak self] _ in self?.setLineFormat(format) }
        })
    }

    /// Changes the text as one step to undo (see `EditorUndo+UIKit`).
    func performEdit(_ range: NSRange, with string: String) -> Bool {
        guard range.upperBound <= storage.length else { return false }
        storage.replaceCharacters(in: range, with: string)
        setSelection(NSRange(location: range.location + (string as NSString).length, length: 0))
        textChanged()
        return true
    }

    // MARK: - UITextViewDelegate

    public func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isLoading else { return }
        let range = textView.selectedRange
        defer { previousSelection = textView.selectedRange }
        closeTypingStep(at: range)
        // The caret steps over bullets and pictures, and a selection takes Markdown whole, as on the Mac. Not while
        // a finger drags the selection's handles, which would make them jump.
        if !isSettingSelection, textView.markedTextRange == nil {
            let fixed = range.length == 0 ? NSRange(location: snapCaret(range.location, from: previousSelection), length: 0) : isTracking ? range : expandSelection(range)
            if fixed != range {
                setSelection(fixed)
                return
            }
        }
        selectionChanged()
        if isTracking { waitForTrackingToEnd() }
    }

    /// Shows what is next to the caret once the finger lifts.
    private func waitForTrackingToEnd() {
        guard !isWaitingForTracking else { return }
        isWaitingForTracking = true
        func check() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if self.isTracking { return check() }
                self.isWaitingForTracking = false
                let range = self.selection
                if range.length > 0 {
                    let expanded = self.expandSelection(range)
                    if expanded != range { self.setSelection(expanded) }
                }
                self.mouseTrackingEnded()
            }
        }
        check()
    }

    public func textViewDidChange(_ textView: UITextView) {
        textChanged()
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !isLoading, !isPerformingEdit, textView.markedTextRange == nil else { return true }
        let selection = self.selection
        // Return picks the suggestion under `[[`.
        if suggestions.isVisible, text == "\n" {
            acceptSelectedSuggestion()
            return false
        }
        if text == "\n", range == selection {
            return !insertNewline()
        }
        if text.isEmpty, selection.length == 0, range.length > 0, range.upperBound == selection.location {
            return !deleteBackward()
        }
        if text == "\t", range == selection {
            return !indent(by: 1)
        }
        return shouldInsert(text, in: range)
    }

    public func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.editorEditingDidChange(self)
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        guard !isMoving else { return }
        delegate?.editorEditingDidChange(self)
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePosition()
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingPlace = nil
    }

    /// Copy Code first in the menu of a selection in a code block.
    public func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.location < storage.length, let block = document.line(containing: range.location)?.block,
              case .code = document.blocks[block].kind else { return nil }
        let start = document.blocks[block].range.location
        let copyCode = UIAction(title: "Copy Code", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyCode(at: start) }
        return UIMenu(children: [copyCode] + suggestedActions)
    }

    // MARK: - Title

    public func textFieldDidBeginEditing(_ textField: UITextField) {
        closeSuggestions()
        delegate?.editorEditingDidChange(self)
    }

    public func textFieldDidEndEditing(_ textField: UITextField) {
        // Moving to another screen isn't leaving the title: it stays as it is being typed. Nor is loading another
        // note, whose title it now is.
        guard !isMoving, !isLoading else { return }
        commitTitle()
        delegate?.editorEditingDidChange(self)
    }

    /// Return in the title goes on to the text.
    @objc private func titleReturn() {
        focusText()
    }

    // MARK: - Taps

    /// Taps on checkboxes, links and pictures are the editor's; everywhere else the text view places the caret.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer.view === textView, !(gestureRecognizer is UIPanGestureRecognizer) else { return true }
        guard let (hit, _) = touchHit(at: gestureRecognizer.location(in: textView)) else { return false }
        if case .headingLevel = hit { return false }
        return true
    }

    /// What a finger hits: the thing under it, or a checkbox right next to it, which is smaller than a fingertip.
    func touchHit(at point: CGPoint) -> (Hit, CGPoint)? {
        if let hit = hitTest(point) { return (hit, point) }
        for offset in [CGPoint(x: 10, y: 0), CGPoint(x: -10, y: 0), CGPoint(x: 0, y: 8), CGPoint(x: 0, y: -8), CGPoint(x: 18, y: 0)] {
            let nearby = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
            if let hit = hitTest(nearby), case .checkbox = hit { return (hit, nearby) }
        }
        return nil
    }

    /// The text view's own taps wait for this one, so a tap on a checkbox neither moves the caret nor brings up the
    /// keyboard.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UITapGestureRecognizer && otherGestureRecognizer.view?.isDescendant(of: textView) == true
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let (hit, point) = touchHit(at: recognizer.location(in: textView)) else { return }
        handleTap(hit, at: point)
    }

    func handleTap(_ hit: Hit, at point: CGPoint) {
        switch hit {
        case .checkbox(let line):
            UISelectionFeedbackGenerator().selectionChanged()
            toggleCheckbox(line: line)
        case .link(let kind):
            closeSuggestions()
            delegate?.editor(self, open: kind)
        case .picture(let range, let url):
            if let url {
                delegate?.editor(self, quickLook: url)
            } else {
                makeTextFirstResponder()
                setSelection(range)
            }
        case .editLink(let range):
            editLink(at: range)
        case .block(_, let caret):
            openBlock(caret: caret, at: point)
        case .headingLevel:
            break
        }
    }

    // MARK: - The keyboard

    /// The note scrolls on under the keyboard: what it covers is room to scroll the caret above it.
    @objc private func keyboardWillChange(_ notification: Notification) {
        guard let window = textView.window,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = window.convert(end, from: window.screen.coordinateSpace)
        let frame = textView.convert(textView.bounds, to: window)
        let hiding = notification.name == UIResponder.keyboardWillHideNotification
        let overlap = hiding ? 0 : max(0, frame.maxY - keyboard.minY - textView.safeAreaInsets.bottom)
        guard textView.contentInset.bottom != overlap else { return }
        textView.contentInset.bottom = overlap
        textView.verticalScrollIndicatorInsets.bottom = overlap
        if overlap > 0, isFocused {
            DispatchQueue.main.async { [weak self] in self?.scrollCaretIntoView() }
        }
    }

    /// Keeps the line with the caret above the keyboard.
    func scrollCaretIntoView() {
        guard let range = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: range.end)
        let bottom = textView.contentOffset.y + textView.bounds.height - textView.adjustedContentInset.bottom - 12
        if caret.maxY > bottom { setScrollTop(min(maxScrollTop, textView.contentOffset.y + caret.maxY - bottom)) }
    }

    // MARK: - Links

    /// The address of a link, which isn't part of the text you see: changed in an alert, as on iOS links are.
    func editLink(at range: NSRange, isNew: Bool = false) {
        guard let link = linkSpan(at: range.location), let presenter = textView.window?.rootViewController?.topmostPresented else { return }
        let address = nsText.substring(with: destinationRange(of: link))
        let alert = UIAlertController(title: isNew ? "Add Link" : "Edit Link", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = address.removingPercentEncoding ?? address
            field.placeholder = "https://"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        let location = range.location
        let entered = { [weak alert] in alert?.textFields?.first?.text ?? "" }
        if !isNew {
            alert.addAction(UIAlertAction(title: "Open", style: .default) { [weak self] _ in
                self?.finishEditingLink(at: location, outcome: .open(entered()), isNew: isNew)
            })
            alert.addAction(UIAlertAction(title: "Remove Link", style: .destructive) { [weak self] _ in
                self?.finishEditingLink(at: location, outcome: .remove, isNew: isNew)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finishEditingLink(at: location, outcome: .save(isNew ? "" : address), isNew: isNew)
        })
        let done = UIAlertAction(title: "Done", style: .default) { [weak self] _ in
            self?.finishEditingLink(at: location, outcome: .save(entered()), isNew: isNew)
        }
        alert.addAction(done)
        alert.preferredAction = done
        presenter.present(alert, animated: true)
    }

    // MARK: - Link suggestions

    func showSuggestions(_ items: [LinkSuggestion], query: String, anchor: Int) {
        guard let start = textView.position(from: textView.beginningOfDocument, offset: anchor - 2) else { return closeSuggestions() }
        let caret = textView.caretRect(for: start)
        let visible = CGRect(x: 0, y: textView.contentOffset.y + textView.adjustedContentInset.top, width: textView.bounds.width,
                             height: textView.bounds.height - textView.adjustedContentInset.top - textView.adjustedContentInset.bottom)
        suggestions.show(items, query: query, below: caret, within: visible, in: textView)
    }

    // MARK: - Pasteboard

    /// Copies the selection as Markdown (and, for a single picture, as that file). Returns false when there is
    /// nothing selected.
    @discardableResult
    func copySelection(cut: Bool) -> Bool {
        guard let clipping = clipping(cut: cut) else { return false }
        var item: [String: Any] = [UTType.utf8PlainText.identifier: clipping.markdown]
        if let data = clipping.fragment { item[Self.fragmentIdentifier] = data }
        if let url = clipping.file {
            item[UTType.fileURL.identifier] = url
            if MarkdownStyler.isImageFile(url), let image = UIImage(contentsOfFile: url.path) { item[UTType.image.identifier] = image }
        }
        UIPasteboard.general.setItems([item])
        if cut { replace(clipping.range, with: "", select: NSRange(location: clipping.range.location, length: 0), actionName: "Cut") }
        return true
    }

    /// Pastes over the selection. Returns false to leave it to UIKit.
    @discardableResult
    func paste(from pasteboard: UIPasteboard) -> Bool {
        let target = selection
        if let data = pasteboard.data(forPasteboardType: Self.fragmentIdentifier), pasteFragment(data, at: target) { return true }
        if let urls = pasteboard.urls?.filter(\.isFileURL), !urls.isEmpty, pasteFiles(urls, at: target) { return true }
        if pasteboard.hasImages, !pasteboard.hasStrings, let image = pasteboard.image, let stored = storeAsset(image: image) {
            insertOnOwnLines("![](\(stored))", at: target)
            return true
        }
        if let string = pasteboard.string {
            pasteText(string, at: target)
            return true
        }
        return false
    }

    // MARK: - Dropping pictures and files

    /// Pictures and files dragged in from Photos or Files go next to the note, as pasted ones do; text dragged
    /// within the note is the text view's.
    public func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
        guard isFileDrop(drop) else { return drop.suggestedProposal }
        let proposal = UITextDropProposal(operation: .copy)
        proposal.dropPerformer = .delegate
        proposal.dropAction = .insert
        return proposal
    }

    private func isFileDrop(_ drop: UITextDropRequest) -> Bool {
        let providers = drop.dropSession.items.map(\.itemProvider)
        return !drop.isSameView && !providers.isEmpty && providers.allSatisfy { provider in
            provider.canLoadObject(ofClass: UIImage.self) || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || (!provider.canLoadObject(ofClass: String.self) && provider.hasItemConformingToTypeIdentifier(UTType.data.identifier))
        }
    }

    public func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
        guard isFileDrop(drop) else { return }
        let location = textView.offset(from: textView.beginningOfDocument, to: drop.dropPosition)
        let providers = drop.dropSession.items.map(\.itemProvider)
        let note = loadCount
        Task { @MainActor in
            var markdown: [String] = []
            for provider in providers {
                if let stored = await self.store(provider) { markdown.append(stored) }
            }
            // Large files take a while: by then another note may be open, which they aren't for.
            guard !markdown.isEmpty, self.loadCount == note else { return }
            self.insertOnOwnLines(markdown.joined(separator: "\n"), at: NSRange(location: min(location, self.storage.length), length: 0))
        }
    }

    /// A dropped item in `.assets`, as Markdown: a picture, or any other file as its card.
    private func store(_ provider: NSItemProvider) async -> String? {
        if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier), provider.canLoadObject(ofClass: UIImage.self) {
            let image: UIImage? = await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
            }
            return image.flatMap { storeAsset(image: $0) }.map { "![](\($0))" }
        }
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        // The file is there only while this runs: it is copied right away.
        let suggestedName = provider.suggestedName
        let copied: String? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                let file = copy.appendingPathComponent(suggestedName.map { $0 + "." + url.pathExtension } ?? url.lastPathComponent)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: file)) != nil ? file.path : nil)
            }
        }
        guard let copied else { return nil }
        let url = URL(fileURLWithPath: copied)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        guard let stored = storeAsset(copying: url) else { return nil }
        return MarkdownStyler.isImageFile(url) ? "![](\(stored))" : "![\(url.lastPathComponent)](\(stored))"
    }

    /// Pictures from the camera, the photo library or the document scanner, saved next to the note and put in at
    /// the caret, each on a line of its own.
    public func insertPictures(_ images: [UIImage]) {
        let stored = images.compactMap { storeAsset(image: $0) }
        guard !stored.isEmpty else { return }
        insertOnOwnLines(stored.map { "![](\($0))" }.joined(separator: "\n"), at: selection)
    }

    /// Files picked in the Files app: copied next to the note, or linked when they are notes.
    public func insertFiles(_ urls: [URL]) {
        _ = pasteFiles(urls, at: selection)
    }
}

extension UIViewController {
    /// The view controller on top, which can present another.
    var topmostPresented: UIViewController {
        var top = self
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}
#endif
