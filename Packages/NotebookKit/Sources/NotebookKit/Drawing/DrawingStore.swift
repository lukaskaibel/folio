#if os(macOS)
import AppKit
#else
import UIKit
#endif
import PencilKit

/// Drawings in notes, as the note shows them when you aren't drawing in them: their area, read at once so a note is
/// laid out right the first time, and their strokes, drawn in the background in light or dark mode at the size they
/// are shown. While a drawing is open in a canvas, what it looks like there counts, before it is saved.
@MainActor
final class DrawingStore {
    static let shared = DrawingStore()

    private struct Key: Hashable {
        var path: String
        var revision: String
        var width: Int
        var isDark: Bool
    }

    private var sizes: [String: (modified: Date?, size: CGSize)] = [:]
    /// Drawn drawings; nil for one with nothing to draw (no strokes, or a strokes file that can't be read).
    private var images: [Key: NSImage?] = [:]
    private var loading: Set<Key> = []
    /// Drawings open in a canvas, with a count of their changes.
    private var live: [String: (file: DrawingFile, revision: Int)] = [:]
    /// Drawings still being drawn.
    var isBusy: Bool { !loading.isEmpty }

    private func modified(_ picture: URL) -> Date? {
        try? DrawingFile.strokesURL(for: picture).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The drawing's area in its own points, or nil when its strokes aren't there (yet).
    func size(of picture: URL) -> CGSize? {
        if let live = live[picture.path] { return live.file.size }
        let date = modified(picture)
        if let cached = sizes[picture.path], cached.modified == date { return cached.size }
        guard let size = DrawingFile.readSize(picture) else { return nil }
        sizes[picture.path] = (date, size)
        return size
    }

    /// What a canvas shows now, or nil once it is closed and the files are what count again.
    func setLive(_ file: DrawingFile?, for picture: URL) {
        if let file {
            let revision = (live[picture.path]?.revision ?? 0) + 1
            live[picture.path] = (file, revision)
        } else {
            live[picture.path] = nil
            sizes[picture.path] = nil
        }
    }

    /// The drawing `width` points wide, if it has been drawn; otherwise it starts drawing it and calls `ready`.
    func image(for picture: URL, width: CGFloat, dark: Bool, ready: @escaping () -> Void) -> NSImage? {
        let scale = Screen.scale
        let pixels = Int((width * scale).rounded())
        let current = live[picture.path]
        let revision = current.map { "live\($0.revision)" } ?? "\(modified(picture)?.timeIntervalSinceReferenceDate ?? 0)"
        let key = Key(path: picture.path, revision: revision, width: pixels, isDark: dark)
        if let image = images[key] { return image }
        // The drawing as it was, or at another size, does until this one is ready.
        let fallback = images.first { $0.key.path == picture.path && $0.key.isDark == dark }?.value ?? nil
        guard !loading.contains(key) else { return fallback }
        loading.insert(key)
        let file = current?.file
        Task.detached(priority: .userInitiated) {
            var image: NSImage?
            if let file = file ?? DrawingFile.read(picture: picture), file.size.width > 0, !file.drawing.strokes.isEmpty {
                let scaleToWidth = CGFloat(pixels) / file.size.width
                if let pixels = DrawingFile.render(file.drawing, in: CGRect(origin: .zero, size: file.size), scale: scaleToWidth, dark: dark) {
                    image = NSImage.make(pixels, scale: scale)
                }
            }
            let drawn = image
            await MainActor.run {
                self.loading.remove(key)
                // Older versions of the drawing aren't needed again.
                self.images = self.images.filter { $0.key.path != key.path || $0.key.revision == key.revision }
                if self.images.count > 60 { self.images.removeAll() }
                self.images[key] = .some(drawn)
                ready()
            }
        }
        return fallback
    }

    /// Draws the drawing now, so it shows without a gap when a canvas closes over it.
    func prepare(_ picture: URL, file: DrawingFile, width: CGFloat, dark: Bool) {
        let scale = Screen.scale
        let pixels = Int((width * scale).rounded())
        guard file.size.width > 0 else { return }
        let revision = "\(modified(picture)?.timeIntervalSinceReferenceDate ?? 0)"
        let key = Key(path: picture.path, revision: revision, width: pixels, isDark: dark)
        guard images[key] == nil else { return }
        let image = file.drawing.strokes.isEmpty ? nil
            : DrawingFile.render(file.drawing, in: CGRect(origin: .zero, size: file.size), scale: CGFloat(pixels) / file.size.width, dark: dark)
        images = images.filter { $0.key.path != key.path }
        images[key] = .some(image.map { NSImage.make($0, scale: scale) })
    }
}
