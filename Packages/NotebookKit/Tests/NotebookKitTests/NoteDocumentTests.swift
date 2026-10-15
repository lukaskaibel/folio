import XCTest
@testable import NotebookKit

/// A note must never lose a change made elsewhere: edits in different places merge, edits in the same place ask.
@MainActor
final class NoteDocumentTests: XCTestCase {
    private func makeNote(_ text: String) -> (NoteDocument, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notebook-notes-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Note.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return (NoteDocument(url: url), url)
    }

    func testSaveMergesChangeMadeElsewhere() throws {
        let (note, url) = makeNote("one\ntwo\nthree\n")
        note.update(text: "one, edited here\ntwo\nthree\n")
        try "one\ntwo\nthree\nfour, added elsewhere\n".write(to: url, atomically: true, encoding: .utf8)
        note.saveNow()
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(saved, "one, edited here\ntwo\nthree\nfour, added elsewhere\n")
        XCTAssertNil(note.conflict)
        note.close()
    }

    func testSameLineChangedBothWaysAsks() throws {
        let (note, url) = makeNote("one\ntwo\n")
        note.update(text: "one mine\ntwo\n")
        try "one theirs\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        note.saveNow()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one theirs\ntwo\n", "nothing is written over")
        XCTAssertEqual(note.conflict?.otherText, "one theirs\ntwo\n")
        _ = note.resolve(.keepBoth)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one mine\ntwo\n")
        let copies = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(copies.contains { $0.hasPrefix("Note (") }, "\(copies)")
        note.close()
    }

    func testDiff3() {
        XCTAssertEqual(Diff3.merge(base: "a\nb\nc", mine: "A\nb\nc", theirs: "a\nb\nC"), "A\nb\nC")
        XCTAssertNil(Diff3.merge(base: "a\nb\nc", mine: "a\nB\nc", theirs: "a\nX\nc"))
    }
}
