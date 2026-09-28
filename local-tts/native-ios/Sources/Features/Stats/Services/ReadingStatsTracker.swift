import Foundation

/// Captures listening sessions from the reader's playback owner
/// (`BookAudioPlayer`, Kokoro-only — the only engine that reaches the
/// reader) and persists them via `ReadingStatsStore` — deliberately a plain,
/// non-observable service, not
/// an `ObservableObject`: nothing in the reader renders stats, so keeping
/// it out of the re-render graph respects this app's re-render-granularity
/// rule (see CLAUDE.md's "object granularity *is* re-render granularity").
///
/// This class only ever does `Date` arithmetic and holds a `UUID` on the
/// main actor — every actual SwiftData read/write happens off-main, inside
/// `ReadingStatsStore`/`ReadingStatsStorageActor`. `ChapterPlayerView`'s
/// read-along is the most performance-tuned surface in this app; nothing
/// here may touch it or block the main thread during playback.
@MainActor
final class ReadingStatsTracker {
    private let store: ReadingStatsStore
    // ~20s backstop, not the primary flush mechanism — pause/endListening/
    // scene-background already flush at every real session boundary. This
    // only exists to survive a hard crash or jetsam kill mid-continuous-
    // playback, the one case those miss.
    private let checkpointInterval: TimeInterval = 20

    private var sessionID: UUID?
    private var accumulatedSeconds: TimeInterval = 0
    // nil while paused; set to the moment the current playing segment
    // started otherwise. listenedSeconds is always derived from this via
    // Date subtraction, never from counting ticks, so a late-firing or
    // suspended timer can't distort it.
    private var segmentStartedAt: Date?
    private var checkpointTask: Task<Void, Never>?

    init(store: ReadingStatsStore) {
        self.store = store
    }

    /// A new page started playing. Any previous session still open is ended
    /// first (page changed mid-playback) — matches how `stop()`/
    /// `stopEnginePlayback()` already precede every new playback start in
    /// both playback owners, so this mirrors an already-established funnel
    /// rather than adding a new one.
    func beginListening(ref: ReaderPageRef, bookTitle: String, voice: String, engine: Engine) {
        if sessionID != nil {
            endListening(pageCompleted: false)
        }
        let id = UUID()
        let startedAt = Date()
        sessionID = id
        accumulatedSeconds = 0
        segmentStartedAt = startedAt
        startCheckpointTimer()
        Task {
            await store.insertSession(
                id: id, startedAt: startedAt, projectID: ref.projectID, bookTitle: bookTitle,
                pageIndex: ref.pageIndex, voiceName: voice, engine: engine)
        }
    }

    func pauseListening() {
        guard sessionID != nil, let segmentStartedAt else { return }
        accumulatedSeconds += Date().timeIntervalSince(segmentStartedAt)
        self.segmentStartedAt = nil
        flush()
    }

    func resumeListening() {
        guard sessionID != nil, segmentStartedAt == nil else { return }
        segmentStartedAt = Date()
    }

    /// `pageCompleted` distinguishes a natural finish (the engine-specific
    /// audio-completion signal fired) from every other way a session ends
    /// (stop, page turn, interruption) — both call this same method, just
    /// with different values.
    func endListening(pageCompleted: Bool) {
        guard let id = sessionID else { return }
        checkpointTask?.cancel()
        checkpointTask = nil
        let total = currentTotal()
        sessionID = nil
        segmentStartedAt = nil
        accumulatedSeconds = 0
        let endedAt = Date()
        Task {
            await store.endSession(
                sessionID: id, listenedSeconds: total, endedAt: endedAt,
                pageCompleted: pageCompleted)
        }
    }

    /// Called from the scene-background hook (`KokoroAneTestApp`'s
    /// `scenePhase` observer) — audio keeps playing once backgrounded and
    /// iOS can kill a suspended app without warning, so flush what's
    /// accrued so far without ending the session, which is still genuinely
    /// in progress.
    func flushForBackgrounding() {
        flush()
    }

    private func currentTotal() -> TimeInterval {
        accumulatedSeconds + (segmentStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func flush() {
        guard let id = sessionID else { return }
        let total = currentTotal()
        Task {
            await store.updateListenedSeconds(sessionID: id, listenedSeconds: total)
        }
    }

    private func startCheckpointTimer() {
        checkpointTask?.cancel()
        let intervalNanoseconds = UInt64(checkpointInterval * 1_000_000_000)
        checkpointTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard !Task.isCancelled, self.sessionID != nil else { return }
                // Skip while paused — nothing is accruing, nothing to write.
                if self.segmentStartedAt != nil {
                    self.flush()
                }
            }
        }
    }
}
