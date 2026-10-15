import AVKit
import SwiftUI

/// A video, played by AVKit right in the window as QuickTime Player plays it: fitted to the column on black, with
/// the system's controls over it. It waits at its first frame until you play it, and stops when you go elsewhere. A
/// video AVFoundation can't play (AVI, MKV and the like) goes to Quick Look (see `FileLoadingView`).
struct VideoFileView: View {
    let url: URL

    var body: some View {
        FileLoadingView(url: url, background: FileKind.video.pageBackground) { url -> AVPlayer? in
            guard FileLoading.read(url, { _ in true }) == true else { return nil }
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true, (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false else { return nil }
            return AVPlayer(playerItem: AVPlayerItem(asset: asset))
        } content: { player in
            PlayerView(player: player)
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
