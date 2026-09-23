import AVFoundation
import SwiftUI

/// Silently loops a bundled video via `AVQueuePlayer` + `AVPlayerLooper` —
/// no audio, no controls, purely decorative. `AVPlayerLooper` (not a manual
/// "seek to zero on end" notification) avoids the visible stutter a manual
/// loop restart causes at the seam.
struct LoopingVideoPlayerView: UIViewRepresentable {
    let url: URL
    var videoGravity: AVLayerVideoGravity = .resizeAspectFill
    /// Freezes on the current frame instead of continuing to play — used to
    /// respect Reduce Motion for what is otherwise an always-on decorative
    /// animation.
    var isPaused: Bool = false

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.videoGravity = videoGravity
        loadPlayer(into: view, context: context)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.playerLayer.videoGravity = videoGravity
        // SwiftUI reuses this same backing UIView/Coordinator across
        // updates rather than recreating it — without this check, picking
        // a different avatar changed `url` but the already-built player
        // kept looping whatever was loaded on first appearance.
        if context.coordinator.url != url {
            loadPlayer(into: uiView, context: context)
            return
        }
        let player = uiView.playerLayer.player
        if isPaused {
            player?.pause()
        } else if player?.timeControlStatus == .paused {
            player?.play()
        }
    }

    private func loadPlayer(into view: PlayerContainerView, context: Context) {
        context.coordinator.url = url
        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        view.playerLayer.player = queuePlayer
        if !isPaused { queuePlayer.play() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        // AVPlayerLooper must be retained for the life of playback, or
        // looping silently stops once it's deallocated.
        var looper: AVPlayerLooper?
        var url: URL?
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
