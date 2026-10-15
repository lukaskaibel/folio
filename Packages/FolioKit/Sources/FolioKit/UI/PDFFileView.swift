import PDFKit
import SwiftUI

/// A PDF, drawn by PDFKit right in the window as Preview draws it: the pages one under the other on the grey behind
/// them, scrolling under the toolbar. The file is read in the background and the pages fade in once it is; until then
/// there is only the grey, and a spinner if that takes long enough to notice. A file still in iCloud says it is
/// downloading. A PDF that PDFKit can't show (damaged, or locked with a password) goes to Quick Look instead.
struct PDFFileView: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var waiting: Waiting?
    @State private var failed = false

    private enum Waiting { case reading, downloading }

    var body: some View {
        if failed {
            QuickLookView(url: url)
        } else {
            ZStack {
                PDFKitView(url: url, document: document)
                    .opacity(document == nil ? 0 : 1)
                    .ignoresSafeArea(.container, edges: .top)
                if document == nil, let waiting {
                    Group {
                        if waiting == .downloading {
                            ProgressView("Downloading from iCloud…")
                        } else {
                            ProgressView()
                        }
                    }
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor).ignoresSafeArea())
            .animation(.easeOut(duration: 0.2), value: document != nil)
            .animation(.easeOut(duration: 0.2), value: waiting != nil)
            .task { await load() }
        }
    }

    private func load() async {
        let inCloud = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus) == .notDownloaded
        // As everywhere on the Mac, nothing spins for a wait too short to notice.
        let indicator = Task {
            try? await Task.sleep(for: .seconds(inCloud ? 0.2 : 0.6))
            if !Task.isCancelled { waiting = inCloud ? .downloading : .reading }
        }
        defer { indicator.cancel() }
        let url = url
        let loaded = await Task.detached(priority: .userInitiated) { () -> PDFDocument? in
            #if DEBUG
            if let delay = Self.debugDelay { try? await Task.sleep(for: .seconds(delay)) }
            #endif
            // A coordinated read waits for iCloud to bring the file down, and for anyone still writing it.
            var document: PDFDocument?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { url in
                document = PDFDocument(url: url)
            }
            return document
        }.value
        guard !Task.isCancelled else { return }
        if let loaded, !loaded.isLocked, loaded.pageCount > 0 {
            document = loaded
        } else {
            failed = true
        }
    }

    #if DEBUG
    /// For the debug remote: makes reading every PDF take this long, to see the wait.
    nonisolated(unsafe) static var debugDelay: TimeInterval?
    #endif
}

/// PDFKit's view, set up like Preview's continuous scroll: the pages fit the width, with page breaks and shadows.
/// It keeps where you were in each PDF, so going back to one (or swiping to it) shows the page you left.
private struct PDFKitView: NSViewRepresentable {
    let url: URL
    let document: PDFDocument?

    /// Where each PDF was left: how far it was scrolled, in the pages' own points, and its zoom unless it fit the width.
    @MainActor private static var places: [URL: (origin: CGPoint, scale: CGFloat?)] = [:]

    func makeCoordinator() -> URL { url }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        view.document = document
        let place = Self.places[url]
        if let scale = place?.scale { view.scaleFactor = scale }
        guard document != nil, let scrollView = view.documentView?.enclosingScrollView else { return }
        // PDFKit fits the pages to the width only now, and keeps the middle of the view where it was, which leaves
        // the first page part way down. It starts at the top instead, below the toolbar, or where it was left.
        view.layoutDocumentView()
        let clip = scrollView.contentView
        clip.scroll(to: place?.origin ?? NSPoint(x: clip.bounds.minX, y: -scrollView.contentInsets.top / scrollView.magnification))
        scrollView.reflectScrolledClipView(clip)
    }

    static func dismantleNSView(_ view: PDFView, coordinator url: URL) {
        guard view.document != nil, let clip = view.documentView?.enclosingScrollView?.contentView else { return }
        places[url] = (clip.bounds.origin, view.autoScales ? nil : view.scaleFactor)
    }
}
