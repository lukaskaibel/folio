#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import PencilKit
import UniformTypeIdentifiers

/// A drawing in a note. The note points at a picture in `.assets`, `![Drawing](.assets/Name.png)`, which every
/// Markdown app shows; next to it, `Name.drawing` keeps the strokes, so Notebook can go on drawing in it. Whenever the
/// strokes change, the picture is made again from them.
struct DrawingFile: Equatable, Sendable {
    /// The strokes, in points from the top left of the drawing's area.
    var drawing: PKDrawing
    /// The drawing's area: as wide as the note's text was where it was made, and as tall as it was drawn. It is shown
    /// as wide as the text is wherever it is opened, larger or smaller.
    var size: CGSize

    static let fileExtension = "drawing"
    /// The version of the strokes file, for a later Notebook that writes it differently.
    static let format = 1
    /// The picture has two pixels for every point, as a screenshot from a Retina display does.
    static let pictureScale: CGFloat = 2

    init(drawing: PKDrawing = PKDrawing(), size: CGSize) {
        self.drawing = drawing
        self.size = size
    }

    /// Where the strokes of the drawing a picture shows are kept: next to it, with the same name.
    static func strokesURL(for picture: URL) -> URL {
        picture.deletingPathExtension().appendingPathExtension(fileExtension)
    }

    /// Whether a picture is a drawing Notebook can go on drawing in: its strokes are there, or in iCloud.
    static func isDrawing(_ picture: URL) -> Bool {
        guard picture.pathExtension.lowercased() == "png" else { return false }
        let strokes = strokesURL(for: picture)
        let inCloud = strokes.deletingLastPathComponent().appendingPathComponent(".\(strokes.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: strokes.path) || FileManager.default.fileExists(atPath: inCloud.path)
    }

    // MARK: - The strokes file

    /// A property list: the format, the area and PencilKit's own data for the strokes.
    func strokesData() -> Data? {
        let list: [String: Any] = [
            "format": Self.format,
            "width": Double(size.width),
            "height": Double(size.height),
            "strokes": drawing.dataRepresentation(),
        ]
        return try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    private static func list(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func size(in list: [String: Any]) -> CGSize? {
        guard let width = list["width"] as? Double, let height = list["height"] as? Double, width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    init?(strokesData data: Data) {
        guard let list = Self.list(data), let size = Self.size(in: list), let strokes = list["strokes"] as? Data,
              let drawing = try? PKDrawing(data: strokes) else { return nil }
        self.init(drawing: drawing, size: size)
    }

    static func read(picture: URL) -> DrawingFile? {
        read(strokesURL(for: picture)).flatMap { DrawingFile(strokesData: $0) }
    }

    /// Read in step with iCloud and other apps writing it.
    private static func read(_ url: URL) -> Data? {
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { url in
            data = try? Data(contentsOf: url)
        }
        return data
    }

    // MARK: - The picture

    /// The strokes as they look in light mode, on white, so they read in any app, in light mode and in dark.
    func picture(scale: CGFloat = pictureScale) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !drawing.strokes.isEmpty, let strokes = Self.render(drawing, in: CGRect(origin: .zero, size: size), scale: scale, dark: false) {
            context.draw(strokes, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()
    }

    /// PNG, marked as 144 dots per inch so apps show it at its size in points, as Notebook does.
    func pictureData() -> Data? {
        guard let image = picture() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * Self.pictureScale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes the strokes and the picture made from them, together, as other devices and apps read them. Making the
    /// picture takes a moment: not on the main thread.
    @discardableResult
    func write(picture: URL) -> Bool {
        guard let strokes = strokesData(), let png = pictureData() else { return false }
        try? FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: Self.strokesURL(for: picture), options: .forReplacing,
                                       writingItemAt: picture, options: .forReplacing, error: nil) { strokesURL, pictureURL in
            written = (try? strokes.write(to: strokesURL, options: .atomic)) != nil
            written = written && (try? png.write(to: pictureURL, options: .atomic)) != nil
        }
        return written
    }

    /// Only the strokes: what makes a picture a drawing, small and quick to write.
    @discardableResult
    func writeStrokes(picture: URL) -> Bool {
        guard let strokes = strokesData() else { return false }
        try? FileManager.default.createDirectory(at: picture.deletingLastPathComponent(), withIntermediateDirectories: true)
        var written = false
        NSFileCoordinator().coordinate(writingItemAt: Self.strokesURL(for: picture), options: .forReplacing, error: nil) { url in
            written = (try? strokes.write(to: url, options: .atomic)) != nil
        }
        return written
    }

    // MARK: - Drawing the strokes

    /// The strokes in `rect` (in the drawing's points) as they look in light or dark mode: PencilKit lightens dark
    /// ink in dark mode, as it does in Notes. Transparent where there are none.
    static func render(_ drawing: PKDrawing, in rect: CGRect, scale: CGFloat, dark: Bool) -> CGImage? {
        #if os(macOS)
        var image: NSImage?
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()).performAsCurrentDrawingAppearance {
            image = drawing.image(from: rect, scale: scale)
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        return image?.cgImage
        #endif
    }
}

extension PKDrawing {
    /// Where the strokes reach down to, or nil when there are none.
    var bottom: CGFloat? {
        strokes.isEmpty ? nil : bounds.maxY
    }
}
