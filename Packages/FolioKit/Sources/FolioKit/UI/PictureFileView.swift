import AppKit
import ImageIO
import SwiftUI

/// A picture, drawn right in the window as Preview and Photos draw it: on the grey behind it, fitted to the column
/// but never larger than it is. Pinch or double-click to zoom in on a spot, and scroll around it; it scrolls under the
/// toolbar like a page. A file that isn't a picture after all goes to Quick Look (see `FileLoadingView`).
struct PictureFileView: View {
    let url: URL

    var body: some View {
        FileLoadingView(url: url, background: FileKind.image.pageBackground) { url in
            FileLoading.read(url, Picture.read)
        } content: { picture in
            PictureCanvas(picture: picture)
                .ignoresSafeArea(.container, edges: .top)
        }
    }
}

/// A picture, read and ready to draw.
struct Picture: @unchecked Sendable {
    /// Decoded already, so drawing it never waits, and turned the way the camera was held.
    let image: CGImage?
    /// An animated GIF, which an image view plays.
    let animation: NSImage?
    /// How big it is, in points, from its resolution, as Preview has it: a Retina screenshot at the size it was on
    /// screen, a scan at the size of the paper.
    let size: CGSize
    /// How many of its pixels make a point.
    let pixelsPerPoint: CGFloat

    /// Pictures larger than this, in pixels on their long side, are decoded smaller. It is still sharper than any
    /// screen when the picture fills it, and keeps a 48-megapixel photo to about 110 MB.
    static let largestSide = 6144

    static func read(_ url: URL) -> Picture? {
        if url.pathExtension.lowercased() == "svg" { return svg(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int, var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 turn the picture a quarter.
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 { swap(&width, &height) }
        // Most photos say 72 dpi; a resolution that makes no sense counts as that too.
        let dpi = min(max(properties[kCGImagePropertyDPIWidth] as? Double ?? 72, 72), 600)
        let pixelsPerPoint = dpi / 72
        let size = CGSize(width: CGFloat(width) / pixelsPerPoint, height: CGFloat(height) / pixelsPerPoint)
        if CGImageSourceGetCount(source) > 1, let animation = NSImage(contentsOf: url),
           let frames = (animation.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int, frames > 1 {
            return Picture(image: nil, animation: animation, size: size, pixelsPerPoint: pixelsPerPoint)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.largestSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return Picture(image: image, animation: nil, size: size, pixelsPerPoint: pixelsPerPoint)
    }

    /// An SVG, which only AppKit reads: drawn once, large enough to stay sharp as far as it zooms.
    private static func svg(_ url: URL) -> Picture? {
        guard let drawing = NSImage(contentsOf: url), drawing.size.width > 0, drawing.size.height > 0 else { return nil }
        let factor = min(PictureScrollView.largestZoom * 2, 4096 / max(drawing.size.width, drawing.size.height))
        let width = Int(drawing.size.width * factor), height = Int(drawing.size.height * factor)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        drawing.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        return Picture(image: image, animation: nil, size: drawing.size, pixelsPerPoint: factor)
    }
}

private struct PictureCanvas: NSViewRepresentable {
    let picture: Picture?

    func makeNSView(context: Context) -> PictureScrollView { PictureScrollView() }

    func updateNSView(_ view: PictureScrollView, context: Context) {
        if let picture, view.picture == nil { view.show(picture) }
    }
}

/// The picture in a scroll view that zooms, as in Preview. It fits the column, below the toolbar, until you zoom in,
/// and goes on fitting as the column changes size. Zoomed in, it scrolls under the toolbar.
final class PictureScrollView: NSScrollView {
    /// How far in it zooms, from its own size in points.
    static let largestZoom: CGFloat = 4

    private(set) var picture: Picture?
    private let canvas = PictureView()
    /// True while the picture fits the column, as it does until you zoom in.
    private(set) var fits = true
    private var isFitting = false

    init() {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        documentView = canvas
        NotificationCenter.default.addObserver(self, selector: #selector(didEndMagnifying), name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ picture: Picture) {
        self.picture = picture
        canvas.show(picture)
        fits = true
        fit()
    }

    /// The zoom at which the whole picture shows below the toolbar, unless it is smaller than that.
    var fittingMagnification: CGFloat {
        guard let picture else { return 1 }
        let width = bounds.width - contentInsets.left - contentInsets.right
        let height = bounds.height - contentInsets.top - contentInsets.bottom
        guard width > 0, height > 0 else { return 1 }
        return min(1, width / picture.size.width, height / picture.size.height)
    }

    override func tile() {
        super.tile()
        fit()
    }

    private func fit() {
        guard picture != nil, !isFitting else { return }
        isFitting = true
        defer { isFitting = false }
        let fitting = fittingMagnification
        minMagnification = fitting
        maxMagnification = max(fitting, Self.largestZoom)
        if fits || magnification < fitting { magnification = fitting }
    }

    @objc private func didEndMagnifying() {
        fits = magnification <= minMagnification + 0.001
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            toggleZoom(at: contentView.convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: contentView.convert(event.locationInWindow, from: nil))
    }

    /// A double click (or a double tap with two fingers) zooms in on the spot, at least far enough to see the
    /// picture's own pixels, and out again to fit.
    func toggleZoom(at point: NSPoint) {
        guard let picture else { return }
        let fitting = fittingMagnification
        let pixels = picture.pixelsPerPoint / (window?.backingScaleFactor ?? 2)
        let target = magnification > fitting + 0.001 ? fitting : min(maxMagnification, max(fitting * 2, pixels))
        fits = target == fitting
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            animator().setMagnification(target, centeredAt: point)
        } completionHandler: { [weak self] in
            // As a pinch does, so the page is pictured again for swiping.
            NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        }
    }
}

/// Keeps a picture smaller than the column in the middle of it, below the toolbar.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView, proposedBounds.width > 0, let insets = enclosingScrollView?.contentInsets else { return rect }
        // The insets are in the scroll view's points, the bounds in the zoomed picture's.
        let scale = frame.width / proposedBounds.width
        let width = rect.width - (insets.left + insets.right) / scale
        if document.frame.width < width {
            rect.origin.x = document.frame.minX - insets.left / scale - (width - document.frame.width) / 2
        }
        let height = rect.height - (insets.top + insets.bottom) / scale
        if document.frame.height < height {
            rect.origin.y = document.frame.minY - (isFlipped ? insets.top : insets.bottom) / scale - (height - document.frame.height) / 2
        }
        return rect
    }
}

/// The picture itself, as a layer's contents: the graphics card scales it, smoothly at every zoom.
private final class PictureView: NSView {
    private var image: CGImage?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func show(_ picture: Picture) {
        setFrameSize(picture.size)
        wantsLayer = true
        if let animation = picture.animation {
            let player = NSImageView(frame: bounds)
            player.image = animation
            player.animates = true
            player.imageScaling = .scaleAxesIndependently
            player.autoresizingMask = [.width, .height]
            addSubview(player)
        } else {
            image = picture.image
            needsDisplay = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.contents = image
        layer.contentsGravity = .resize
        // Mipmaps, so a large photo shown small doesn't shimmer.
        layer.minificationFilter = .trilinear
    }
}
