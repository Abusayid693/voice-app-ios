import AVFoundation

/// Plays a random bundled Kokoro voice-preview clip (`VoicePreviews/Kokoro/*.wav`)
/// — a placeholder for `ClassicReadsSection`'s play button, which has no real
/// book audio to preview. Deliberately its own Service, not inline on
/// `ClassicReadsViewModel`, per this codebase's rule that a ViewModel never
/// touches `AVFoundation` directly.
final class RandomClipPreviewService {
    private var player: AVAudioPlayer?
    private var playerDelegate: AudioPlaybackDelegate?

    /// Stops whatever's playing, then starts a freshly-chosen random clip.
    /// No-ops (rather than crashing) if the bundle has no clips, which
    /// shouldn't happen given `VoicePreviews/Kokoro/` is a bundled resource.
    /// There's no play/pause state to reset on completion (unlike
    /// `VoicePreviewPlayer`) — a finished clip's player is simply replaced
    /// by the next `play()`, so the delegate callback needs no handler.
    func play() {
        stop()
        guard let url = Self.randomClipURL() else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = AudioPlaybackDelegate {}
            player.delegate = delegate
            playerDelegate = delegate
            self.player = player
            player.play()
        } catch {
            player = nil
            playerDelegate = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playerDelegate = nil
    }

    private static func randomClipURL() -> URL? {
        Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: "VoicePreviews/Kokoro")?.randomElement()
    }
}
