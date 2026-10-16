import SwiftUI

/// A file Notebook draws itself rather than through Quick Look, which shows a dashed box while it loads. The file is
/// read in the background; until then there is only the background, a spinner if that takes long enough to notice,
/// and "Downloading from iCloud…" for a file still in iCloud. Then it fades in. A file that can't be read this way
/// goes to Quick Look after all.
///
/// `content` is there from the start, without what was read, so a scroll view in it is already in the window (and
/// knows the toolbar's height) when the file arrives.
struct FileLoadingView<Loaded, Content: View>: View {
    let url: URL
    let background: NSColor
    let read: @Sendable (URL) async -> Loaded?
    @ViewBuilder let content: (Loaded?) -> Content

    @State private var loaded: Loaded?
    @State private var waiting: Waiting?
    @State private var failed = false

    private enum Waiting { case reading, downloading }

    var body: some View {
        if failed {
            QuickLookView(url: url)
        } else {
            ZStack {
                content(loaded)
                    .opacity(loaded == nil ? 0 : 1)
                if loaded == nil, let waiting {
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
            // Up under the toolbar, but not under the sidebar's and the inspector's glass, which would take on its tint.
            .background(Color.theme(background).ignoresSafeArea(.container, edges: .top))
            .animation(.easeOut(duration: 0.2), value: loaded == nil)
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
        let url = url, read = read
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            #if DEBUG
            if let delay = FileLoading.debugDelay { try? await Task.sleep(for: .seconds(delay)) }
            #endif
            return await read(url)
        }.value
        guard !Task.isCancelled else { return }
        if let result {
            loaded = result
        } else {
            failed = true
        }
    }
}

enum FileLoading {
    /// Reads a file in a coordinated read, which waits for iCloud to bring it down, and for anyone still writing it.
    static func read<Result>(_ url: URL, _ body: (URL) -> Result?) -> Result? {
        var result: Result?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { url in
            result = body(url)
        }
        return result
    }

    #if DEBUG
    /// For the debug remote: makes reading every file shown this way take this long, to see the wait.
    nonisolated(unsafe) static var debugDelay: TimeInterval?
    #endif
}

extension FileKind {
    /// What lies around the file in the window: the grey Preview puts behind pages and pictures, or black behind a
    /// video, as in QuickTime Player.
    var pageBackground: NSColor {
        switch self {
        #if os(macOS)
        case .pdf, .image: .underPageBackgroundColor
        #else
        case .pdf, .image: .secondarySystemBackground
        #endif
        case .video: .black
        default: Theme.panel
        }
    }
}
