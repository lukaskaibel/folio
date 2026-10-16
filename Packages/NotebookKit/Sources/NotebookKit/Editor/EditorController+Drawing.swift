#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PencilKit

/// Drawing mode: the drawings of the note open in canvases over the text, and the tools are out.
@MainActor
final class DrawingSession {
    /// The canvas over each drawing in the note, by its picture.
    var canvases: [URL: DrawingCanvas] = [:]
    /// Drawings put in when drawing mode started, with the text that was there: one still empty when it ends goes
    /// again, and the note is as it was.
    var created: [URL: (location: Int, inserted: String, replaced: String)] = [:]
    /// The drawing drawn in last, or the one drawing mode started in.
    var focused: URL?
    /// How far down each drawing's strokes reach, so it grows only when a stroke goes further down.
    var bottoms: [URL: CGFloat] = [:]
    var saveWork: DispatchWorkItem?
    #if os(iOS)
    let toolPicker = PKToolPicker()
    #endif
}

/// Drawing in a note, as in Notes: the pencil button puts the note into drawing mode, in which every drawing in it
/// takes strokes (from Apple Pencil, a finger, a mouse or a tablet) and the text can't be drawn on. If the caret isn't
/// on a drawing, a new one goes in next to its line (at the end of the note when you aren't writing), as wide as the
/// text; it grows as you draw near its lower edge. A tap on a drawing (a double-click on the Mac) opens it for drawing too.
///
/// Each drawing is a picture in `.assets` that every Markdown app shows, with its strokes next to it
/// (`DrawingFile`); both are written a moment after every change.
extension EditorController {
    /// A stroke that goes this close to a drawing's lower edge (in its points) makes it grow, to three times as much
    /// room below it.
    static let drawingRoom: CGFloat = 56
    /// A drawing is never shorter than this once it is trimmed to its strokes.
    static let drawingMinimumHeight: CGFloat = 48

    public var isDrawing: Bool { drawingSession != nil }

    /// The pencil button: starts drawing, or stops.
    public func toggleDrawing() {
        if isDrawing { endDrawing() } else { beginDrawing() }
    }

    /// Starts drawing mode: in `picture`, in the drawing at the caret, or in a new drawing put in there.
    public func beginDrawing(in picture: URL? = nil) {
        guard !isDrawing, !isLoading, assetsFolder != nil else { return }
        closeSuggestions()
        let session = DrawingSession()
        var target = picture ?? drawingAtCaret()
        if target == nil {
            guard let (url, insertion) = insertDrawing() else { return beep() }
            session.created[url] = insertion
            target = url
        }
        session.focused = target
        drawingSession = session
        startDrawingInput()
        updateDrawingCanvases()
        if let target {
            focusCanvas(target)
            scrollDrawingIntoView(target)
        }
        delegate?.editorDrawingDidChange(self)
    }

    /// Stops drawing mode: the drawings are saved and drawn in the text again. A new one left empty goes away. The
    /// character at `keeping` (the one clicked to stop) stays where it is on screen.
    public func endDrawing(keeping anchor: Int? = nil) {
        guard let session = drawingSession else { return }
        session.saveWork?.cancel()
        for canvas in session.canvases.values where canvas.isEdited { trim(canvas) }
        saveDrawings(waiting: true)
        let empty = session.created.filter { picture, _ in session.canvases[picture]?.file.drawing.strokes.isEmpty ?? true }
        let dark = isDarkAppearance
        for (picture, canvas) in session.canvases {
            DrawingStore.shared.setLive(nil, for: picture)
            DrawingStore.shared.prepare(picture, file: canvas.file, width: canvas.frame.width, dark: dark)
        }
        drawingSession = nil
        stopDrawingInput(session)
        var anchor = anchor
        for (picture, insertion) in empty {
            let removed = removeDrawing(picture, insertion: insertion)
            if let range = removed, let index = anchor, index >= range.location {
                anchor = max(range.location, index - range.length)
            }
        }
        relayoutDrawings(Array(session.canvases.keys), anchor: anchor)
        delegate?.editorDrawingDidChange(self)
    }

    /// Stops drawing to write: the caret goes on the line below the drawing drawn in last, a new one when the next
    /// line has text, so typing goes on after the drawing rather than over the caret's old place.
    public func endDrawingToWrite() {
        let picture = drawingSession?.focused
        endDrawing()
        makeTextFirstResponder()
        guard let picture, let index = drawingIndex(picture) else { return }
        let line = nsText.lineRange(for: NSRange(location: index, length: 0))
        let endsWithBreak = line.upperBound > line.location && nsText.character(at: line.upperBound - 1) == 10
        if !endsWithBreak {
            replace(NSRange(location: line.upperBound, length: 0), with: "\n", select: NSRange(location: line.upperBound + 1, length: 0), actionName: "Typing")
            return
        }
        let next = nsText.lineRange(for: NSRange(location: line.upperBound, length: 0))
        if line.upperBound < storage.length, nsText.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            replace(NSRange(location: line.upperBound, length: 0), with: "\n", select: NSRange(location: line.upperBound, length: 0), actionName: "Typing")
        } else {
            setSelection(NSRange(location: line.upperBound, length: 0))
        }
    }

    /// Writes what was drawn now: the app is going to the background or quitting.
    public func saveDrawingsNow() {
        drawingSession?.saveWork?.cancel()
        saveDrawings(waiting: true)
    }

    func showsCanvas(for picture: URL) -> Bool {
        drawingSession?.canvases[picture] != nil
    }

    /// The canvas under a point in the text view.
    func canvas(at point: NSPoint) -> DrawingCanvas? {
        drawingSession?.canvases.values.first { $0.frame.contains(point) }
    }

    // MARK: - Finding drawings

    /// The drawings in the note, in order, with the character each is on.
    func drawingObjects() -> [(index: Int, picture: URL)] {
        var found: [(Int, URL)] = []
        storage.enumerateAttribute(.notebookObject, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let object = value as? EditorObject, case .drawing(let picture) = object.kind { found.append((range.location, picture)) }
        }
        return found
    }

    private func drawingIndex(_ picture: URL) -> Int? {
        drawingObjects().first { $0.picture == picture }?.index
    }

    /// The drawing on the caret's line, or selected, while you are in the text.
    func drawingAtCaret() -> URL? {
        let selection = self.selection
        guard isFocused || selection.length > 0, selection.location <= storage.length else { return nil }
        let line = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        return drawingObjects().first { NSLocationInRange($0.index, line) }?.picture
    }

    /// The drawing a picture object is, if it is one.
    func drawing(at range: NSRange) -> URL? {
        guard let object = layoutManager.object(at: range.location), case .drawing(let picture) = object.kind else { return nil }
        return picture
    }

    // MARK: - A new drawing

    /// Writes an empty drawing as wide as the text and puts it in on a line of its own: on the caret's line if it is
    /// empty, above it with the caret at its start, below it otherwise, so no text is split. At the end of the note
    /// a line follows it to go on writing in.
    private func insertDrawing() -> (URL, (location: Int, inserted: String, replaced: String))? {
        guard let picture = newDrawingURL() else { return nil }
        let width = floor(max(40, container.size.width - 2))
        let height = min(max(visibleRect.height * 0.42, 220), 420).rounded()
        guard DrawingFile(size: CGSize(width: width, height: height)).write(picture: picture) else { return nil }
        let markdown = "![Drawing](\(Self.markdownPath(picture.lastPathComponent)))"
        let caret = isFocused && caretWasPlaced ? min(selection.location, storage.length) : storage.length
        let line = nsText.lineRange(for: NSRange(location: caret, length: 0))
        var lineEnd = line.upperBound
        if lineEnd > line.location, lineEnd <= storage.length, nsText.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let content = NSRange(location: line.location, length: lineEnd - line.location)
        let atEnd = lineEnd == storage.length
        let range: NSRange
        let text: String
        if nsText.substring(with: content).trimmingCharacters(in: .whitespaces).isEmpty {
            range = content
            text = markdown + (atEnd ? "\n" : "")
        } else if caret == line.location {
            range = NSRange(location: line.location, length: 0)
            text = markdown + "\n"
        } else {
            range = NSRange(location: lineEnd, length: 0)
            text = "\n" + markdown + (atEnd ? "\n" : "")
        }
        let replaced = nsText.substring(with: range)
        replace(range, with: text, select: NSRange(location: range.location + (text as NSString).length, length: 0), actionName: "Insert Drawing")
        return (picture, (range.location, text, replaced))
    }

    /// "Note drawing 2026-10-16 at 10.20.15.png", with neither the picture nor its strokes there yet.
    private func newDrawingURL() -> URL? {
        guard let assets = assetsFolder else { return nil }
        try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "\(delegate?.editorNoteName(self) ?? "Note") drawing \(formatter.string(from: Date()))"
        for counter in 1... {
            let picture = assets.appendingPathComponent((counter == 1 ? base : "\(base) \(counter)") + ".png")
            if !FileManager.default.fileExists(atPath: picture.path), !FileManager.default.fileExists(atPath: DrawingFile.strokesURL(for: picture).path) {
                return picture
            }
        }
        return nil
    }

    /// Takes out a drawing put in at the start of drawing mode, putting back what was there, and its files. Returns
    /// where the text was taken out and how much shorter it got.
    @discardableResult
    private func removeDrawing(_ picture: URL, insertion: (location: Int, inserted: String, replaced: String)) -> NSRange? {
        defer {
            try? FileManager.default.removeItem(at: picture)
            try? FileManager.default.removeItem(at: DrawingFile.strokesURL(for: picture))
        }
        let inserted = NSRange(location: insertion.location, length: (insertion.inserted as NSString).length)
        if inserted.upperBound <= storage.length, nsText.substring(with: inserted) == insertion.inserted {
            replace(inserted, with: insertion.replaced, select: NSRange(location: insertion.location + (insertion.replaced as NSString).length, length: 0), actionName: "Delete Drawing")
            return NSRange(location: inserted.location, length: inserted.length - (insertion.replaced as NSString).length)
        } else if let index = drawingIndex(picture), let object = layoutManager.object(at: index) {
            let line = nsText.lineRange(for: object.range(at: index))
            replace(line, with: "", select: NSRange(location: line.location, length: 0), actionName: "Delete Drawing")
            return line
        }
        return nil
    }

    // MARK: - Canvases

    /// Puts a canvas over every drawing in the note, where the drawing is laid out, and takes away the canvases of
    /// drawings no longer there (undone, cut). Called whenever the layout may have moved them.
    func updateDrawingCanvases() {
        guard let session = drawingSession else { return }
        var seen = Set<URL>()
        let origin = textOrigin
        for (index, picture) in drawingObjects() where !seen.contains(picture) {
            seen.insert(picture)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(storage.length, index + 1)))
            guard let rect = layoutManager.blockObjectRect(at: index, origin: origin) else { continue }
            let canvas: DrawingCanvas
            if let existing = session.canvases[picture] {
                canvas = existing
            } else {
                guard let file = DrawingFile.read(picture: picture) else { continue }
                canvas = DrawingCanvas(picture: picture, file: file, editor: self)
                session.canvases[picture] = canvas
                session.bottoms[picture] = file.drawing.bottom
                DrawingStore.shared.setLive(file, for: picture)
                attachCanvas(canvas)
            }
            canvas.place(in: rect)
        }
        for (picture, canvas) in session.canvases where !seen.contains(picture) {
            if canvas.hasUnsavedChanges { save(canvas) }
            detachCanvas(canvas)
            session.canvases[picture] = nil
            DrawingStore.shared.setLive(nil, for: picture)
        }
    }

    /// A stroke was drawn or erased, or undone: the drawing grows when a stroke goes further down than any before and
    /// near its lower edge, and is saved a moment later.
    func drawingDidChange(_ canvas: DrawingCanvas) {
        guard let session = drawingSession, session.canvases[canvas.picture] === canvas else { return }
        canvas.isEdited = true
        canvas.hasUnsavedChanges = true
        session.focused = canvas.picture
        var file = canvas.file
        var grew = false
        let before = session.bottoms[canvas.picture]
        session.bottoms[canvas.picture] = file.drawing.bottom
        if let bottom = file.drawing.bottom, bottom > (before ?? -.infinity) + 0.5, bottom > file.size.height - Self.drawingRoom {
            file.size.height = (bottom + Self.drawingRoom * 3).rounded()
            canvas.file = file
            grew = true
        }
        DrawingStore.shared.setLive(file, for: canvas.picture)
        if grew { relayoutDrawings([canvas.picture]) }
        scheduleDrawingSave()
    }

    /// A stroke started in a canvas: it gets the tools.
    func canvasDidBeginStroke(_ canvas: DrawingCanvas) {
        drawingSession?.focused = canvas.picture
    }

    /// After drawing, the drawing is as tall as its strokes, so it doesn't leave the room it grew by in the note.
    private func trim(_ canvas: DrawingCanvas) {
        guard let bottom = canvas.file.drawing.bottom else { return }
        let height = max(Self.drawingMinimumHeight, (bottom + 16).rounded())
        guard height < canvas.file.size.height - 0.5 else { return }
        canvas.file.size.height = height
        canvas.hasUnsavedChanges = true
    }

    /// Lays the lines of drawings out again, at their new height, without moving what is above them on screen (or
    /// the character at `anchor`).
    private func relayoutDrawings(_ pictures: [URL], anchor: Int? = nil) {
        let indexes = drawingObjects().filter { pictures.contains($0.picture) }.map(\.index)
        guard let first = indexes.min() else { return }
        preservingScroll(anchor: anchor ?? first) {
            for index in indexes {
                let line = nsText.lineRange(for: NSRange(location: index, length: 0))
                layoutManager.invalidateLayout(forCharacterRange: line, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: line)
            }
        }
        updateDrawingCanvases()
        textNeedsDisplay()
    }

    private func scrollDrawingIntoView(_ picture: URL) {
        guard let index = drawingIndex(picture), let rect = layoutManager.blockObjectRect(at: index, origin: textOrigin) else { return }
        let visible = visibleRect
        let top = visible.minY + topInset
        // The tools take the bottom of the window.
        let bottom = visible.maxY - drawingToolsHeight
        guard rect.minY < top || rect.maxY > bottom else { return }
        // Just enough to see all of it, or its top when it is taller than the room there is.
        let target = rect.minY < top || rect.height > bottom - top - 32
            ? visible.minY + rect.minY - top - 16
            : visible.minY + rect.maxY - bottom + 16
        setScrollTop(min(max(-topInset, target), max(-topInset, maxScrollTop)))
        updateDrawingCanvases()
    }

    // MARK: - Saving

    private func scheduleDrawingSave() {
        guard let session = drawingSession else { return }
        session.saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveDrawings(waiting: false) }
        session.saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Writes the drawings that changed, in the background; `waiting` until they are written.
    private func saveDrawings(waiting: Bool) {
        guard let session = drawingSession else { return }
        for canvas in session.canvases.values where canvas.hasUnsavedChanges { save(canvas) }
        if waiting { DrawingFile.writing.sync {} }
    }

    private func save(_ canvas: DrawingCanvas) {
        canvas.hasUnsavedChanges = false
        let file = canvas.file, picture = canvas.picture
        DrawingFile.writing.async { file.write(picture: picture) }
    }
}

extension DrawingFile {
    /// Drawings are written one after another, away from the main thread: making the picture takes a moment.
    static let writing = DispatchQueue(label: "com.lukaskbl.notebook.drawings", qos: .userInitiated)
}
