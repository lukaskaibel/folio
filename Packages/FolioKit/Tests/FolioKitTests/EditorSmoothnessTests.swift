import AppKit
import XCTest
@testable import FolioKit

/// Typing must stay instant in long notes, and nothing on screen may jump when things change out of view.
@MainActor
final class EditorSmoothnessTests: XCTestCase {
    private func longNote(sections: Int) -> String {
        var text = ""
        for index in 0..<sections {
            text += """
            ## Section \(index)
            Some **bold** text, *italics*, a [[Budget]] link and `code` in paragraph \(index), long enough to wrap onto a second line in the editor.
            - [ ] A task
            - [x] A done task
              - nested item with ~~strike~~
            > A quote

            | A | B |
            | --- | --- |
            | \(index) | two |

            ```swift
            let value = \(index) // comment
            ```

            """
        }
        return text
    }

    func testTypingInLongNoteIsFast() {
        let h = EditorHarness(longNote(sections: 150))
        XCTAssertGreaterThan(h.text.count, 40_000)
        let middle = h.range(of: "paragraph 75").location
        h.caret(middle)
        var times: [Double] = []
        for character in "quick brown fox " {
            let start = CACurrentMediaTime()
            h.textView.insertText(String(character), replacementRange: h.textView.selectedRange())
            h.editor.layoutManager.ensureLayout(forCharacterRange: NSRange(location: middle, length: 200))
            times.append(CACurrentMediaTime() - start)
        }
        let average = times.reduce(0, +) / Double(times.count)
        print("typing in a \(h.text.count) character note: average \(Int(average * 1000)) ms, worst \(Int((times.max() ?? 0) * 1000)) ms")
        XCTAssertLessThan(average, 0.016, "a keystroke fits in one frame")
    }

    func testBlockClosingAboveViewDoesNotMoveWhatYouSee() {
        let h = EditorHarness(longNote(sections: 12), height: 600)
        // Open the first table for editing: it shows its Markdown, taller than the rendered table.
        let table = h.range(of: "| A | B |")
        h.caret(table.location + 2)
        XCTAssertNotNil(h.editor.activeBlock)
        // Scroll far below it and click there: the table closes above the visible part.
        let target = h.range(of: "paragraph 6")
        let clip = h.editor.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: h.editor.yPosition(of: target.location) - 200))
        h.editor.scrollView.reflectScrolledClipView(clip)
        let before = h.editor.yPosition(of: target.location) - clip.bounds.minY
        h.click(at: h.point(of: target.location))
        XCTAssertNil(h.editor.activeBlock, "the table closed")
        let after = h.editor.yPosition(of: target.location) - clip.bounds.minY
        XCTAssertEqual(before, after, accuracy: 1, "the line you clicked stays where it was on screen")
    }

    func testDeadKeysComposeCharacters() {
        let h = EditorHarness("Cafe ")
        h.caret(5)
        // ´ then e, as on a German keyboard: the accent waits as marked text, then becomes é.
        h.textView.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle(0)
        XCTAssertTrue(h.textView.hasMarkedText())
        h.textView.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle(0)
        XCTAssertFalse(h.textView.hasMarkedText())
        XCTAssertEqual(h.text, "Cafe é")
    }

    func testMarkedTextInsideBoldKeepsStyle() {
        let h = EditorHarness("a **bold** b")
        h.caret(5)
        h.textView.setMarkedText("¨", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        h.textView.insertText("ö", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.settle(0)
        XCTAssertEqual(h.text, "a **böold** b")
        let font = h.editor.storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(EditorStyle.weight(of: font ?? .systemFont(ofSize: 1)), 0.2, "the new letter is bold like the rest")
    }
}
