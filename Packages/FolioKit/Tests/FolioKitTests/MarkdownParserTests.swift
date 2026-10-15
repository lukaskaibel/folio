import XCTest
@testable import FolioKit

final class MarkdownParserTests: XCTestCase {
    private func spans(_ text: String) -> [(InlineSpan.Kind, String)] {
        let doc = MarkdownParser.parse(text)
        let ns = text as NSString
        return doc.lines.flatMap(\.spans).map { ($0.kind, ns.substring(with: $0.content)) }
    }

    private func kinds(_ text: String) -> [LineKind] {
        MarkdownParser.parse(text).lines.map(\.kind)
    }

    func testEmphasis() {
        let result = spans("a **bold** and *it* and ***both*** and ~~gone~~")
        XCTAssertTrue(result.contains { $0.0 == .strong && $0.1 == "bold" })
        XCTAssertTrue(result.contains { $0.0 == .emphasis && $0.1 == "it" })
        XCTAssertTrue(result.contains { $0.0 == .strikethrough && $0.1 == "gone" })
        XCTAssertTrue(result.contains { $0.0 == .strong && $0.1 == "*both*" } || result.contains { $0.0 == .emphasis && $0.1 == "**both**" })
    }

    func testUnderscoreInsideWordsIsNotEmphasis() {
        XCTAssertTrue(spans("snake_case_name here").isEmpty)
        XCTAssertEqual(spans("_yes_").first?.0, .emphasis)
    }

    func testUnclosedMarkersStayText() {
        XCTAssertTrue(spans("**not closed").isEmpty)
        XCTAssertTrue(spans("2 * 3 * 4").isEmpty)
    }

    func testCodeSpanWinsOverEmphasis() {
        let result = spans("`a *b* c` *d*")
        XCTAssertEqual(result.map(\.0), [.code, .emphasis])
        XCTAssertEqual(result.first?.1, "a *b* c")
    }

    func testLinksImagesWikiLinks() {
        let result = spans("see [the docs](https://x.dev/a_(b)) and ![pic](.assets/a b.jpg) and [[Budget]] and [[Kyoto trip|the trip]] ![[Offer.pdf]]")
        XCTAssertTrue(result.contains { $0.0 == .link(destination: "https://x.dev/a_(b)") && $0.1 == "the docs" })
        XCTAssertTrue(result.contains { $0.0 == .image(source: ".assets/a", alt: "pic") } || result.contains { if case .image = $0.0 { true } else { false } })
        XCTAssertTrue(result.contains { $0.0 == .wikiLink(target: "Budget", alias: nil) && $0.1 == "Budget" })
        XCTAssertTrue(result.contains { $0.0 == .wikiLink(target: "Kyoto trip", alias: "the trip") && $0.1 == "the trip" })
        XCTAssertTrue(result.contains { $0.0 == .embed(target: "Offer.pdf") })
    }

    func testMathAndPrices() {
        XCTAssertEqual(spans("costs $5 and $10 today").count, 0)
        let result = spans("solve $x^2 = 4$ now")
        XCTAssertEqual(result.first?.0, .math(tex: "x^2 = 4"))
    }

    func testBareURL() {
        let result = spans("go to https://example.com/path. Then")
        XCTAssertEqual(result.first?.0, .autolink(url: "https://example.com/path"))
    }

    func testBlocks() {
        let text = """
        ---
        tags: [a]
        ---
        # Title
        - one
          - two
        1. first
        - [ ] todo
        - [x] done
        > [!tip] Hint
        > body
        ```swift
        let a = 1
        ```
        | A | B |
        | --- | :-: |
        | 1 | 2 |
        $$
        x^2
        $$
        ***
        """
        let doc = MarkdownParser.parse(text)
        XCTAssertEqual(doc.blocks.map(\.kind), [
            .frontmatter, .callout(type: "tip"), .code(language: "swift"), .table(alignments: [.leading, .center]), .math,
        ])
        let lines = doc.lines.map(\.kind)
        if case .heading(let level, _) = lines[3] { XCTAssertEqual(level, 1) } else { XCTFail("heading") }
        if case .listItem(let item) = lines[5] { XCTAssertEqual(item.level, 1) } else { XCTFail("nested item") }
        if case .listItem(let item) = lines[7] { XCTAssertTrue(item.isTask); XCTAssertFalse(item.checked) } else { XCTFail("task") }
        if case .listItem(let item) = lines[8] { XCTAssertTrue(item.checked) } else { XCTFail("done task") }
        XCTAssertEqual(lines.last, .thematicBreak)
    }

    func testListContentStartsAfterPrefix() {
        let text = "  - [ ] call mum"
        let doc = MarkdownParser.parse(text)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: doc.lines[0].content), "call mum")
    }

    func testTrailingNewlineMakesEmptyLastLine() {
        let doc = MarkdownParser.parse("a\n")
        XCTAssertEqual(doc.lines.count, 2)
        XCTAssertEqual(doc.lines[1].range, NSRange(location: 2, length: 0))
        XCTAssertEqual(doc.lineIndex(containing: 2), 1)
    }

    func testUnclosedFenceRunsToEnd() {
        let doc = MarkdownParser.parse("```\ncode\nmore")
        XCTAssertEqual(doc.blocks.first?.lines, 0...2)
    }
}
