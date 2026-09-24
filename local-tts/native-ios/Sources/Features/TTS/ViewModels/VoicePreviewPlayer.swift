import AVFoundation
import Combine

/// Plays a voice's bundled preview clip — pure file playback, no synthesis,
/// so it never touches the TTS engines and can't collide with an
/// in-progress "Write text" generation.
///
/// Deliberately its own observable object rather than more state on
/// `TTSViewModel`: the metering loop below updates `level`/`progress` ~15
/// times a second, and while that lived on the shared view model every
/// view observing it — including Import's whole 70-tile Trending scroll —
/// re-rendered at that rate for the duration of every preview. Now only
/// the two views that actually show preview state observe it.
@MainActor
final class VoicePreviewPlayer: ObservableObject {
    /// Which voice is currently playing, if any — drives play/pause icons.
    @Published private(set) var playingVoiceID: String?
    /// 0...1 playback position, and a 0...1 normalized live audio level;
    /// the preview sheet's progress track and its cover art's
    /// audio-reactive pulse bind to these directly.
    @Published private(set) var progress: Double = 0
    @Published private(set) var level: Double = 0

    private var player: AVAudioPlayer?
    private var playerDelegate: AudioPlaybackDelegate?
    private var meterTask: Task<Void, Never>?

    /// True if this voice has a bundled clip — independent of whether its
    /// pack is *downloaded*, since this is pure bundled-file playback.
    /// Voices with no pack downloaded still preview fine; voices with no
    /// clip recorded yet (all of Pocket TTS today — see
    /// docs/adr/0009-bundled-voice-preview-clips.md) can't preview even
    /// when their pack is present.
    func hasClip(voiceName: String, engine: Engine) -> Bool {
        Self.clipURL(voiceName: voiceName, engine: engine) != nil
    }

    /// Plays, or stops if this voice is already playing. No-ops when the
    /// clip isn't bundled yet.
    func toggle(voiceName: String, engine: Engine) {
        let wasPlayingThisVoice = playingVoiceID == voiceName
        stop()
        guard !wasPlayingThisVoice else { return }
        guard let url = Self.clipURL(voiceName: voiceName, engine: engine) else { return }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.isMeteringEnabled = true
            let delegate = AudioPlaybackDelegate { [weak self] in
                Task { @MainActor in
                    guard let self, self.playingVoiceID == voiceName else { return }
                    self.stop()
                }
            }
            player.delegate = delegate
            playerDelegate = delegate
            self.player = player
            playingVoiceID = voiceName
            player.play()
            startMetering(for: player)
        } catch {
            playingVoiceID = nil
        }
    }

    /// Stops whatever is playing and resets progress/level — called both on
    /// an explicit stop and when a clip finishes on its own.
    func stop() {
        meterTask?.cancel()
        meterTask = nil
        player?.stop()
        player = nil
        playerDelegate = nil
        playingVoiceID = nil
        progress = 0
        level = 0
    }

    private static func clipURL(voiceName: String, engine: Engine) -> URL? {
        let engineFolder: String
        switch engine {
        case .kokoroAne: engineFolder = "Kokoro"
        case .pocketTts: engineFolder = "Pocket"
        }
        let subdirectory = "VoicePreviews/\(engineFolder)"
        return Bundle.main.url(forResource: voiceName, withExtension: "wav", subdirectory: subdirectory)
    }

    /// Polls metering ~15x/second while playing, exiting on its own once
    /// the player stops (finished or replaced).
    private func startMetering(for player: AVAudioPlayer) {
        meterTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.player === player, player.isPlaying {
                player.updateMeters()
                self.level = Self.normalizedLevel(fromDecibels: player.averagePower(forChannel: 0))
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
                try? await Task.sleep(nanoseconds: 66_000_000)
            }
        }
    }

    /// Metering reports roughly -160 (silence) to 0 dB (peak) — clamping to
    /// a narrower, perceptually-useful floor (speech rarely nears 0 dB)
    /// keeps the pulse visible instead of pinned near zero.
    private static func normalizedLevel(fromDecibels power: Float) -> Double {
        let floorDb: Float = -50
        let clamped = max(power, floorDb)
        return Double((clamped - floorDb) / -floorDb)
    }
}
