import AVFoundation

/// Bridges `AVAudioPlayerDelegate`'s completion callback to a plain closure,
/// so an owner doesn't have to conform to `NSObject` itself. Callers must
/// hold a strong reference — `AVAudioPlayer.delegate` is weak.
final class AudioPlaybackDelegate: NSObject, AVAudioPlayerDelegate {
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
