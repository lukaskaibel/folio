#if os(iOS)
import ImageIO
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

/// Everything that isn't a note, a PDF, a picture or a video, shown by Quick Look right in the page.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Source { Source(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Source: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// A picture, shown as Photos and Files show one: fitted to the page on its grey, never larger than it is. Pinch or
/// double-tap to zoom in on a spot. A file that isn't a picture after all goes to Quick Look.
struct PictureFileView: View {
    let url: URL

    var body: some View {
        FileLoadingView(url: url, background: FileKind.image.pageBackground) { url in
            FileLoading.read(url, TouchPicture.read)
        } content: { picture in
            PictureZoomView(picture: picture)
        }
    }
}

/// A picture, decoded and turned the way the camera was held, or an animated GIF's frames.
struct TouchPicture: @unchecked Sendable {
    let image: UIImage

    /// Pictures larger than this, in pixels on their long side, are decoded smaller: still sharper than the screen.
    static let largestSide = 6144

    static func read(_ url: URL) -> TouchPicture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let count = CGImageSourceGetCount(source)
        if count > 1 {
            var frames: [UIImage] = []
            var duration = 0.0
            for index in 0..<min(count, 400) {
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
                frames.append(UIImage(cgImage: frame))
                let gif = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            if frames.count > 1, let animation = UIImage.animatedImage(with: frames, duration: duration) { return TouchPicture(image: animation) }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.largestSide),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Most photos say 72 dpi; a screenshot or scan says more, and shows at the size it had.
        let dpi = min(max(properties[kCGImagePropertyDPIWidth] as? Double ?? 72, 72), 600)
        return TouchPicture(image: UIImage(cgImage: image, scale: dpi / 72, orientation: .up))
    }
}

private struct PictureZoomView: UIViewRepresentable {
    let picture: TouchPicture?

    func makeUIView(context: Context) -> PictureScrollView { PictureScrollView() }

    func updateUIView(_ view: PictureScrollView, context: Context) {
        if view.imageView.image !== picture?.image { view.show(picture?.image) }
    }
}

/// A scroll view that fits its picture and zooms it.
final class PictureScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    init() {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.accessibilityIgnoresInvertColors = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: UIImage?) {
        imageView.image = image
        imageView.frame = CGRect(origin: .zero, size: image?.size ?? .zero)
        contentSize = imageView.frame.size
        fitted = nil
        setNeedsLayout()
    }

    private var fitted: CGSize?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let area = bounds.inset(by: safeAreaInsets).insetBy(dx: 12, dy: 12)
        // Fitted, but never larger than the picture is.
        let fit = min(1, area.width / image.size.width, area.height / image.size.height)
        if fitted != bounds.size {
            let wasFitted = fitted == nil || abs(zoomScale - minimumZoomScale) < 0.001
            fitted = bounds.size
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 4, 4)
            if wasFitted { zoomScale = fit }
        }
        centre()
    }

    /// Keeps the picture in the middle of the page while it is smaller than the page.
    private func centre() {
        let size = imageView.frame.size
        let area = bounds.inset(by: safeAreaInsets)
        let x = max(0, (area.width - size.width) / 2) + safeAreaInsets.left
        let y = max(0, (area.height - size.height) / 2) + safeAreaInsets.top
        contentInset = UIEdgeInsets(top: y, left: x, bottom: safeAreaInsets.bottom, right: 0)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centre() }

    /// Twice to zoom in on the spot, twice again to fit.
    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.001 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = recognizer.location(in: imageView)
            let scale = min(maximumZoomScale, max(minimumZoomScale * 2.5, 1))
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// A file's icon as the system draws it: its thumbnail for documents and pictures, its kind's icon otherwise.
struct FileIcon: View {
    let url: URL
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
            } else {
                Image(systemName: FileKind(url: url, isDirectory: false).symbol)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 128, height: 128), scale: 3, representationTypes: .all)
            thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
    }
}
#endif
