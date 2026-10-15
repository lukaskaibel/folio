import AppKit
import XCTest
@testable import FolioKit

/// Headings without visible #s, links with their address behind a pencil, highlights, typography and export.
@MainActor
final class EditorFeatureTests: XCTestCase {
    private let note = "Intro line\n## Packing\nSome text with [the site](https://example.com) and ==marked words== here."

    // MARK: - Headings

    func testHeadingMarksNeverShowAndTheLevelShowsInTheMargin() throws {
        let h = EditorHarness(note)
        let marker = h.range(of: "## ")
        h.caret(h.range(of: "Packing").location + 3)
        XCTAssertTrue(h.editor.layoutManager.isHidden(marker.location), "the #s stay hidden with the caret on the heading")
        XCTAssertTrue(h.editor.isRevealed(marker.location), "the heading counts as being edited")
        XCTAssertEqual(h.editor.storage.attribute(.folioHeading, at: marker.location, effectiveRange: nil) as? Int, 2)
        let rect = try XCTUnwrap(h.editor.layoutManager.headingMarkRect(at: marker.location, origin: h.textView.textContainerOrigin))
        XCTAssertLessThan(rect.maxX, h.textView.textContainerOrigin.x, "the tag is in the margin, left of the text")
        let tag = try XCTUnwrap(h.pixel(at: CGPoint(x: rect.minX + 3, y: rect.midY)))
        XCTAssertGreaterThan(tag.alphaComponent, 0.5, "the tag is drawn")

        h.caret(h.range(of: "Intro").location)
        let away = try XCTUnwrap(h.pixel(at: CGPoint(x: rect.minX + 3, y: rect.midY)))
        XCTAssertLessThan(away.alphaComponent, 0.1, "the tag goes when the caret leaves the heading")
    }

    func testCaretStaysOutOfHiddenHeadingMarks() {
        let h = EditorHarness(note)
        let marker = h.range(of: "## ")
        h.caret(marker.location + 1)
        XCTAssertEqual(h.selection.location, marker.upperBound)
    }

    func testBackspaceAtTheStartOfAHeadingMakesItBodyText() {
        let h = EditorHarness(note)
        h.caret(h.range(of: "Packing").location)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(h.text, "Intro line\nPacking\nSome text with [the site](https://example.com) and ==marked words== here.")
    }

    func testTypingHashAndSpaceMakesAHeading() {
        let h = EditorHarness("Intro\n")
        h.caret(6)
        h.type("# Title")
        XCTAssertEqual(h.text, "Intro\n# Title")
        XCTAssertTrue(h.editor.layoutManager.isHidden(6), "the # disappears once the space follows it")
    }

    func testCopyingAWholeHeadingKeepsItAHeading() {
        let h = EditorHarness(note)
        h.select(h.range(of: "Packing"))
        h.textView.copy(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "## Packing")
    }

    // MARK: - Links

    func testLinkAddressIsHiddenBehindAPencil() {
        let h = EditorHarness(note)
        let link = h.range(of: "[the site](https://example.com)")
        let close = h.range(of: "](https")
        h.caret(h.range(of: "the site").location + 2)
        XCTAssertTrue(h.editor.layoutManager.isHidden(link.location), "the [ stays hidden")
        XCTAssertTrue(h.editor.layoutManager.isHidden(close.location + 2), "the address stays hidden")
        if case .linkEdit = h.editor.layoutManager.object(at: close.location)?.kind {} else { XCTFail("the pencil sits after the text") }
    }

    func testCaretGoesAroundTheHiddenAddress() {
        let h = EditorHarness(note)
        let link = h.range(of: "[the site](https://example.com)")
        h.caret(h.range(of: "https").location)
        XCTAssertEqual(h.selection.location, link.upperBound)
    }

    func testBackspaceAfterALinkDeletesItsText() {
        let h = EditorHarness(note)
        let link = h.range(of: "[the site](https://example.com)")
        h.caret(link.upperBound)
        h.command(#selector(NSResponder.deleteBackward(_:)))
        XCTAssertTrue(h.text.contains("[the sit](https://example.com)"), h.text)
    }

    // MARK: - Highlights and to-dos

    func testHighlightIsParsedAndToggled() {
        let spans = InlineParser.spans(in: Array("a ==b c== d".utf16), range: NSRange(location: 0, length: 11))
        XCTAssertEqual(spans.first?.kind, .highlight)
        let h = EditorHarness("plain words")
        h.select(NSRange(location: 6, length: 5))
        h.textView.toggleHighlight(nil)
        XCTAssertEqual(h.text, "plain ==words==")
    }

    func testDoneToDosAreGreyNotStruckThrough() {
        let h = EditorHarness("- [x] Passport")
        let index = h.range(of: "Passport").location
        XCTAssertNil(h.editor.storage.attribute(.strikethroughStyle, at: index, effectiveRange: nil))
        XCTAssertEqual(h.editor.storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor, Theme.textTertiary)
    }

    // MARK: - Typography and export

    func testTypographySetsTheWholeNoteAgain() {
        let settings = FolioSettings.shared
        let saved = settings.typography
        defer { settings.typography = saved }
        let h = EditorHarness(note)
        settings.typography.size = 19
        settings.typography.face = .serif
        let font = h.editor.storage.attribute(.font, at: h.range(of: "Intro").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 19)
        XCTAssertTrue(font?.fontName.lowercased().contains("newyork") == true || font?.familyName?.contains("New York") == true, font?.fontName ?? "")
    }

    func testExportMakesAPDFAndAPicture() async throws {
        let h = EditorHarness(note)
        let pdfData = await NoteExporter.data(for: h.editor, title: "Kyoto trip", as: .pdf)
        let pdf = try XCTUnwrap(pdfData)
        XCTAssertEqual(String(data: pdf.prefix(4), encoding: .ascii), "%PDF")
        let pngData = await NoteExporter.data(for: h.editor, title: "Kyoto trip", as: .png)
        let png = try XCTUnwrap(pngData)
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThan(image.pixelsHigh, 200)
    }
}
