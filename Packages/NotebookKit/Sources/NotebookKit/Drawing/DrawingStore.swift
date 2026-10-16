#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PencilKit

/// Drawings in notes, as the note shows them when you aren't drawing in them: their strokes, read and drawn in the
/// background, in light or dark mode at the size they are shown. Nothing here reads a file on the main thread: a
/// drawing's size comes from its picture's header, as a picture's does, until its strokes are read.
///
/// While a drawing is open in a canvas, and until what was drawn is written, what it looks like there counts.
@MainActor
final class DrawingStore {
    static let shared = DrawingStore()

    private struct Key: Hashable {
        var path: String
        var revision: String
        var width: Int
        var isDark: Bool
    }

    /// Drawn drawings; nil for one with nothing to draw (no strokes, or a strokes file that can't be read).
    private var images: [Key: NSImage?] = [:]
    private var drawing: Set<Key> = []
    /// Drawings open in a canvas or not written yet, with a count of their changes.
    private var live: [String: (file: DrawingFile, revision: Int)] = [:]
    /// Strokes read from disk, with the strokes file's date then.
    private var files: [String: (modified: Date?, file: DrawingFile)] = [:]
    private var reading: [String: [(DrawingFile?) -> Void]] = [:]
    /// Drawings still being drawn.
    var isBusy: Bool { !drawing.isEmpty }

    nonisolated private static func modified(_ picture: URL) -> Date? {
        try? DrawingFile.strokesURL(for: picture).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func revision(of picture: URL) -> String {
        if let live = live[picture.path] { return "live\(live.revision)" }
        return "disk\(Self.modified(picture)?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// The drawing's area in its own points, if it is open or its strokes have been read.
    func size(of picture: URL) -> CGSize? {
        live[picture.path]?.file.size ?? files[picture.path]?.file.size
    }

    /// The strokes as they are now, if they are open or have been read and not changed since.
    func file(for picture: URL) -> DrawingFile? {
        if let live = live[picture.path] { return live.file }
        guard let cached = files[picture.path], cached.modified == Self.modified(picture) else { return nil }
        return cached.file
    }

    /// Reads the strokes in the background (downloading them from iCloud if need be) and calls `ready` with them.
    func read(_ picture: URL, ready: @escaping (DrawingFile?) -> Void) {
        if let file = file(for: picture) { return ready(file) }
        if reading[picture.path] != nil {
            reading[picture.path]?.append(ready)
            return
        }
        reading[picture.path] = [ready]
        Task.detached(priority: .userInitiated) {
            let file = DrawingFile.read(picture: picture)
            let date = Self.modified(picture)
            await MainActor.run {
                if let file { self.files[picture.path] = (date, file) }
                let waiting = self.reading.removeValue(forKey: picture.path) ?? []
                waiting.forEach { $0(file) }
            }
        }
    }

    /// Counts every change, so a revision is never used twice.
    private var changes = 0

    /// What a canvas shows now.
    func setLive(_ file: DrawingFile, for picture: URL) {
        changes += 1
        live[picture.path] = (file, changes)
    }

    /// The canvas closed without a change: the files are what count again.
    func close(_ picture: URL) {
        live[picture.path] = nil
    }

    /// The live revision of a drawing, to tell `didSave` which one was written.
    func liveRevision(of picture: URL) -> Int? {
        live[picture.path]?.revision
    }

    /// Drawings open in a canvas, which stay live until the canvas closes.
    private var open: Set<String> = []
    /// The last revision of each drawing written, and the strokes file's date after.
    private var saved: [String: (revision: Int, modified: Date?)] = [:]

    /// What was drawn is written.
    func didSave(_ file: DrawingFile, picture: URL, revision: Int, modified: Date?) {
        files[picture.path] = (modified, file)
        saved[picture.path] = (revision, modified)
        settle(picture)
    }

    func setOpen(_ isOpen: Bool, _ picture: URL) {
        if isOpen { open.insert(picture.path) } else { open.remove(picture.path) }
        settle(picture)
    }

    /// Closed and written as it is: the files count again, and the drawing as it is drawn now is kept for them, so it
    /// isn't drawn again.
    private func settle(_ picture: URL) {
        guard !open.contains(picture.path), let current = live[picture.path], let written = saved[picture.path],
              written.revision == current.revision else { return }
        live[picture.path] = nil
        let disk = "disk\(written.modified?.timeIntervalSinceReferenceDate ?? 0)"
        for (key, image) in images where key.path == picture.path && key.revision == "live\(current.revision)" {
            images[Key(path: key.path, revision: disk, width: key.width, isDark: key.isDark)] = image
        }
    }

    /// The drawing `width` points wide, if it has been drawn; otherwise it starts drawing it and calls `ready`.
    func image(for picture: URL, width: CGFloat, dark: Bool, ready: @escaping () -> Void) -> NSImage? {
        let scale = Screen.scale
        let pixels = Int((width * scale).rounded())
        let key = Key(path: picture.path, revision: revision(of: picture), width: pixels, isDark: dark)
        if let image = images[key] { return image }
        // The drawing as it was, or at another size, does until this one is ready.
        let fallback = images.first { $0.key.path == picture.path && $0.key.isDark == dark }?.value ?? nil
        guard !drawing.contains(key) else { return fallback }
        drawing.insert(key)
        let known = file(for: picture)
        Task.detached(priority: .userInitiated) {
            let file = known ?? DrawingFile.read(picture: picture)
            let date = known == nil ? Self.modified(picture) : nil
            var image: NSImage?
            if let file, file.size.width > 0, !file.drawing.strokes.isEmpty,
               let drawn = DrawingFile.render(file.drawing, in: CGRect(origin: .zero, size: file.size), scale: CGFloat(pixels) / file.size.width, dark: dark) {
                image = NSImage.make(drawn, scale: scale)
            }
            let result = image
            await MainActor.run {
                self.drawing.remove(key)
                if known == nil, let file { self.files[picture.path] = (date, file) }
                // Older versions of the drawing aren't needed again.
                self.images = self.images.filter { $0.key.path != key.path || $0.key.revision == key.revision }
                if self.images.count > 60 { self.images.removeAll() }
                self.images[key] = .some(result)
                ready()
            }
        }
        return fallback
    }

    /// Draws the drawing as it is now, so it shows without a gap when a canvas closes over it.
    func prepare(_ picture: URL, width: CGFloat, dark: Bool) {
        guard let file = file(for: picture), file.size.width > 0 else { return }
        let scale = Screen.scale
        let pixels = Int((width * scale).rounded())
        let key = Key(path: picture.path, revision: revision(of: picture), width: pixels, isDark: dark)
        guard images[key] == nil else { return }
        let image = file.drawing.strokes.isEmpty ? nil
            : DrawingFile.render(file.drawing, in: CGRect(origin: .zero, size: file.size), scale: CGFloat(pixels) / file.size.width, dark: dark)
        images = images.filter { $0.key.path != key.path }
        images[key] = .some(image.map { NSImage.make($0, scale: scale) })
    }
}
