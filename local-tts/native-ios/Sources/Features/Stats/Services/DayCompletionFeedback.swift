import AudioToolbox
import CoreHaptics
import UIKit

/// Haptic + chime fired once a day-orb selection lands on a day that met its
/// goal.
///
/// Deliberately never touches `AVAudioSession` — a book or voice preview may
/// be playing through this app's shared session, and re-categorising it for a
/// one-shot tick would risk interrupting that. `playsHapticsOnly` keeps Core
/// Haptics off the session; System Sound Services is independent of it.
@MainActor
enum DayCompletionFeedback {
    /// Wallet's "Payment Success" chime. Undocumented (no public constant),
    /// but `AudioServicesPlaySystemSound` no-ops on an unrecognised ID, so a
    /// future OS retiring it degrades to silence rather than breaking.
    private static let successSoundID: SystemSoundID = 1322

    /// Where the haptic pattern's release pop lands. `play()` delays the
    /// chime to the same instant so the two read as one moment.
    private static let releaseTime: TimeInterval = 0.17

    /// One engine reused for the app's lifetime per Core Haptics' own
    /// guidance — starting one has real latency. `nil` where custom haptics
    /// are unsupported (the Simulator); callers fall back to
    /// `UINotificationFeedbackGenerator`.
    private static let engine: CHHapticEngine? = {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        let engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        // The system stops an idle engine and can reset it on a route change;
        // restart rather than leaving every later call fail silently.
        engine?.resetHandler = { [weak engine] in try? engine?.start() }
        engine?.stoppedHandler = { _ in }
        return engine
    }()

    static func play() {
        if playHaptic() {
            DispatchQueue.main.asyncAfter(deadline: .now() + releaseTime) {
                AudioServicesPlaySystemSound(successSoundID)
            }
        } else {
            // The fallback buzz is flat and immediate, with no lead-in to
            // sync against — delaying the chime would just leave it trailing.
            AudioServicesPlaySystemSound(successSoundID)
        }
    }

    /// Anticipation tap, rising swell, crisp release pop — three events on
    /// one intensity curve rather than `UINotificationFeedbackGenerator`'s
    /// single flat buzz. Returns whether that richer pattern actually played,
    /// so `play()` knows whether its delayed chime has anything to sync to.
    @discardableResult
    private static func playHaptic() -> Bool {
        guard let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return false
        }
        do {
            try engine.start()

            let anticipation = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2),
                ],
                relativeTime: 0)

            let swell = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.55),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
                ],
                relativeTime: 0.03,
                duration: 0.13)

            let swellRamp = CHHapticParameterCurve(
                parameterID: .hapticIntensityControl,
                controlPoints: [
                    .init(relativeTime: 0, value: 0.3),
                    .init(relativeTime: 0.13, value: 1.0),
                ],
                relativeTime: 0.03)

            let release = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.65),
                ],
                relativeTime: releaseTime)

            let pattern = try CHHapticPattern(
                events: [anticipation, swell, release], parameterCurves: [swellRamp])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return false
        }
    }
}
