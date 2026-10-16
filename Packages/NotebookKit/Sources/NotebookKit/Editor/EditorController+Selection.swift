#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Selection that behaves like Apple Notes: the caret steps around bullets, checkboxes, pictures and links to notes as
/// if each were one character, and a selection takes such things whole, along with the hidden punctuation of
/// formatting it covers completely, so deleting or copying never leaves half a construct behind.
extension EditorController {
    /// The end of a line's prefix that is drawn as one thing (a bullet, a checkbox, a quote bar).
    func atomicPrefixEnd(_ line: MarkdownLine) -> Int? {
        switch line.kind {
        case .listItem(let item): item.prefix.upperBound
        case .quote(_, let prefix): prefix.upperBound
        case .heading(_, let marker): isHidden(marker) ? marker.upperBound : nil
        default: nil
        }
    }

    /// A link being typed (its `[[` popup open) is text you edit, not one thing yet.
    func isAtomic(_ span: InlineSpan) -> Bool {
        span.isAtomic && !isComposing(span)
    }

    func isComposing(_ span: InlineSpan) -> Bool {
        guard let anchor = suggestionAnchor, case .wikiLink = span.kind else { return false }
        return span.range.location == anchor - 2
    }

    func snapCaret(_ location: Int, from old: NSRange) -> Int {
        guard !document.lines.isEmpty, location <= storage.length else { return location }
        let lineIndex = document.lineIndex(containing: location)
        let line = document.lines[lineIndex]
        // Where the caret comes from: arrow keys move it by one character.
        let previous = old.length == 0 ? old.location : (location <= old.location ? old.location : old.upperBound)
        let stepped = abs(location - previous) <= 1

        for span in line.spans where isAtomic(span) && span.range.strictlyContains(location) {
            if stepped { return location > previous ? span.range.upperBound : span.range.location }
            return location - span.range.location <= span.range.upperBound - location ? span.range.location : span.range.upperBound
        }

        if let contentStart = atomicPrefixEnd(line), location < contentStart, location >= line.range.location {
            // Left from the start of an item's text goes to the end of the line above.
            if stepped, location < previous, previous == contentStart, lineIndex > 0 {
                return document.lines[lineIndex - 1].range.upperBound
            }
            return contentStart
        }

        // A link's address is hidden behind its pencil: the caret is before the pencil or after it.
        for span in line.spans {
            guard case .link = span.kind, location > span.content.upperBound, location < span.range.upperBound else { continue }
            if stepped { return location > previous ? span.range.upperBound : span.content.upperBound }
            return span.range.upperBound
        }

        // Leading spaces hidden in front of a picture on a line of its own.
        if let object = blockObjectSpan(in: line), location < object.location, location > line.range.location {
            return stepped && location < previous ? line.range.location : object.location
        }
        return location
    }

    /// Whether a range is hidden for good (a heading's #s once they are followed by a space).
    func isHidden(_ range: NSRange) -> Bool {
        guard range.length > 0, range.location < storage.length,
              let mode = storage.attribute(.notebookHidden, at: range.location, effectiveRange: nil) as? Int else { return false }
        return mode == HiddenMode.always.rawValue
    }

    /// The picture or embed that is a whole line on its own.
    func blockObjectSpan(in line: MarkdownLine) -> NSRange? {
        guard line.kind == .paragraph else { return nil }
        guard let index = line.range.location < storage.length ? line.range.location : nil else { return nil }
        for location in index..<line.range.upperBound {
            if let object = layoutManager.object(at: location), object.isBlock { return object.range(at: location) }
        }
        return nil
    }

    func expandSelection(_ range: NSRange) -> NSRange {
        guard !document.lines.isEmpty else { return range }
        var start = range.location
        var end = min(range.upperBound, storage.length)
        let first = document.lineIndex(containing: start)
        let last = document.lineIndex(containing: max(start, end - 1))
        // Twice, for formatting inside formatting (***both***).
        for _ in 0..<2 {
            for index in first...last {
                let line = document.lines[index]
                for span in line.spans {
                    if isAtomic(span) {
                        if span.range.strictlyContains(start) { start = span.range.location }
                        if span.range.strictlyContains(end) { end = span.range.upperBound }
                    } else if !span.markers.isEmpty, span.content.length > 0,
                              start <= span.content.location, end >= span.content.upperBound,
                              start >= span.range.location || end <= span.range.upperBound {
                        if start > span.range.location { start = span.range.location }
                        if end < span.range.upperBound { end = span.range.upperBound }
                    }
                }
                if let block = line.block, document.blocks[block].isSwappable, block != activeBlock {
                    let range = document.blocks[block].range
                    if range.strictlyContains(start) { start = range.location }
                    if range.strictlyContains(end) { end = range.upperBound }
                }
                if let object = blockObjectSpan(in: line) {
                    if object.strictlyContains(start) { start = object.location }
                    if object.strictlyContains(end) { end = object.upperBound }
                }
            }
        }
        return NSRange(location: start, length: max(0, end - start))
    }
}
