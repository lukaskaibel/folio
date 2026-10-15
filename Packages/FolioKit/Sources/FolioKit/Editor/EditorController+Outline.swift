import AppKit

/// A heading in the note, for the outline next to it.
public struct OutlineHeading: Identifiable, Equatable {
    /// Its place among the headings, so the list doesn't animate on every keystroke.
    public var id: Int
    public var level: Int
    public var title: String
    public var location: Int
}

/// How long the note is.
public struct NoteStats: Equatable {
    public var words = 0
    public var characters = 0

    /// At about 230 words a minute.
    public var readingMinutes: Int { max(1, Int((Double(words) / 230).rounded())) }
}

extension EditorController {
    /// Reads the headings and counts the words once typing pauses.
    func scheduleOutlineUpdate() {
        outlineUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateOutline() }
        outlineUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func updateOutline() {
        outlineUpdate?.cancel()
        outlineUpdate = nil
        let text = nsText
        var headings: [OutlineHeading] = []
        for line in document.lines {
            guard case .heading(let level, _) = line.kind else { continue }
            let title = plainText(of: line).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            headings.append(OutlineHeading(id: headings.count, level: level, title: title, location: line.range.location))
        }
        var words = 0
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        let stats = NoteStats(words: words, characters: text.length)
        let changed = headings != outline || stats != self.stats
        outline = headings
        self.stats = stats
        if changed { delegate?.editorOutlineDidChange(self) }
        updatePosition(force: changed)
    }

    /// A heading's words without the Markdown around them: `**Plan** for [[Kyoto]]` reads "Plan for Kyoto".
    private func plainText(of line: MarkdownLine) -> String {
        let text = nsText
        var hidden = IndexSet()
        for span in line.spans {
            for marker in span.markers { hidden.insert(integersIn: marker.location..<marker.upperBound) }
        }
        var result = ""
        var index = line.content.location
        while index < line.content.upperBound {
            if let next = hidden.integerGreaterThanOrEqualTo(index), next < line.content.upperBound {
                result += text.substring(with: NSRange(location: index, length: next - index))
                index = hidden.rangeView.first(where: { $0.contains(next) }).map(\.upperBound) ?? next + 1
            } else {
                result += text.substring(with: NSRange(location: index, length: line.content.upperBound - index))
                break
            }
        }
        // A closing run of #s is part of the heading's punctuation.
        while result.hasSuffix("#") { result.removeLast() }
        return result
    }

    // MARK: - Where you are

    @objc func scrolled() {
        updatePosition()
        updateCopyButtonForPointer()
    }

    /// The top of what you see, below the toolbar, in the text view's coordinates.
    var visibleTop: CGFloat { scrollView.contentView.bounds.minY + scrollView.contentInsets.top }

    func updatePosition(force: Bool = false) {
        let titleAway = textView.titleField.frame.midY < visibleTop
        var current: Int?
        if !outline.isEmpty, storage.length > 0 {
            // The section a reader is in is the one whose heading is above a line or two below the toolbar.
            let y = visibleTop + 40 - textView.textContainerOrigin.y
            var index = 0
            if y > 0 {
                let glyph = layoutManager.glyphIndex(for: NSPoint(x: 1, y: y), in: container)
                index = layoutManager.characterIndexForGlyph(at: glyph)
            }
            current = outline.lastIndex { $0.location <= index }
            // With the title in view, you are at the start of the note.
            if scrollView.contentView.bounds.minY <= -scrollView.contentInsets.top + 1 { current = nil }
            // Scrolled to the very bottom, the last headings can't reach the top: the last one you can see counts.
            let clip = scrollView.contentView
            if clip.bounds.minY > -scrollView.contentInsets.top + 1, clip.bounds.maxY >= textView.frame.height - 2, let last = outline.indices.last,
               yPosition(of: outline[last].location) < clip.bounds.maxY {
                current = last
            }
        }
        if let jump {
            if isJumping || abs(scrollView.contentView.bounds.minY - jump.y) < 1 { current = jump.heading } else { self.jump = nil }
        }
        guard force || titleAway != isTitleScrolledAway || current != currentHeading else { return }
        isTitleScrolledAway = titleAway
        currentHeading = current
        delegate?.editorPositionDidChange(self)
    }

    // MARK: - Scrolling

    func scrollToTop() {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where you are in the note: how far it is scrolled and where the caret is.
    public struct Place {
        var scroll: CGFloat
        var selection: NSRange
    }

    public var place: Place {
        Place(scroll: scrollView.contentView.bounds.minY, selection: textView.selectedRange())
    }

    /// Comes back to a place in the note, as Back and Forward do: the same caret, scrolled to the same spot.
    public func restore(_ place: Place) {
        guard place.selection.upperBound <= storage.length else { return }
        textView.setSelectedRange(place.selection)
        let clip = scrollView.contentView
        layoutManager.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: container.size.width, height: place.scroll + clip.bounds.height), in: container)
        let top = -scrollView.contentInsets.top
        let bottom = max(top, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(top, place.scroll), bottom)))
        scrollView.reflectScrolledClipView(clip)
        updatePosition()
    }

    /// Scrolls a heading up to just below the toolbar, or to the title for `nil`. The caret stays where it is.
    public func scroll(to heading: OutlineHeading?, animated: Bool = true) {
        let clip = scrollView.contentView
        let top = -scrollView.contentInsets.top
        var y = top
        if let heading, heading.location < storage.length {
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: heading.location + 1))
            y = yPosition(of: heading.location) + top - 18
        }
        let bottom = max(top, textView.frame.height - clip.bounds.height)
        let origin = NSPoint(x: clip.bounds.minX, y: min(max(top, y), bottom))
        jump = (heading?.id, origin.y)
        guard animated else {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            updatePosition()
            return
        }
        isJumping = true
        updatePosition()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isJumping = false
                self?.scrollView.reflectScrolledClipView(clip)
                self?.updatePosition()
            }
        }
    }
}
