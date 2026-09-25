import AVFoundation
import Foundation

/// The single owner of every chapter `AVAudioPlayer` in the app — both the
/// saved path (one merged file, real duration/scrubbing) and the
/// streaming path (synthesize-and-play, chunk by chunk). One object, one
/// `player` field, so "play chapter 2 while chapter 1 streams" is just
/// `stop()` then start the new one — the same shape
/// `VoicePreviewPlayer.toggle` already proves correct. Kept off
/// `TTSViewModel` per this app's own re-render rule: the scrubber ticks
/// ~4x/sec, and `TTSViewModel`-observing views (VoicesTabView's grid,
/// voice pickers) shouldn't re-render for that.
///
/// Streaming has two independent cursors, not one: synthesis always marches
/// forward through a chapter's chunks in the background, retaining each
/// one's audio/word-timings/duration in memory (cheap — one chapter's
/// worth of short WAVs) so both directions of seeking work; playback reads
/// from that growing store and can be repositioned anywhere already
/// retained, catching up and buffering (`playbackWaitingForIndex`) if it
/// reaches a chunk synthesis hasn't produced yet. This lets `duration`
/// grow as chunks arrive (the scrubber's own bound) without seeking ever
/// needing to trigger synthesis out of order.
enum ChapterPlaybackMode: Equatable {
    case saved
    case streaming
}

@MainActor
final class ChapterAudioPlayer: ObservableObject {
    @Published private(set) var activeRef: ReaderPageRef?
    @Published private(set) var mode: ChapterPlaybackMode?
    @Published private(set) var isPlaying = false
    /// True from a natural finish until playback restarts or repositions.
    /// A finished `AVAudioPlayer` reports `currentTime == 0`, and the
    /// read-along highlight is deliberately *not* gated on `isPlaying` (so it
    /// survives a pause) — so without this it recomputed from a reset clock
    /// at the end of a page and snapped back to the first word of the chunk
    /// that had just finished.
    private var hasFinishedPlayback = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentChunkIndex = 0

    /// Read-along text for whichever mode is active — the saved
    /// manifest's chunk texts, or the streaming chunks as they're known.
    /// Published despite changing rarely: `ChapterPlayerView` derives its
    /// whole paragraph structure from this, and while it was unpublished
    /// that structure only refreshed when some *other* property happened to
    /// publish (the 4 Hz ticker), landing a frame late or not at all.
    @Published private(set) var chunkTexts: [String] = []

    private var player: AVAudioPlayer?
    private var delegate: AudioPlaybackDelegate?
    private var manifest: ChapterAudioManifest?
    private var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var isScrubbing = false

    // Streaming-only: retained per-chunk results, in-memory for this
    // session only (never written to disk — see ChapterSynthesisService
    // .generateAndSave for the persisted path). Index-parallel to
    // chunkTexts. `playbackWaitingForIndex` is set when playback finishes
    // a chunk but the next one hasn't been synthesized yet.
    private var streamingChunkAudio: [Data] = []
    private var streamingWordTimingsStore: [[WordTiming]] = []
    private var streamingChunkDurations: [TimeInterval] = []
    private var playbackWaitingForIndex: Int?

    private let synthesisService: ChapterSynthesisService
    private let statsTracker: ReadingStatsTracker

    init(synthesisService: ChapterSynthesisService, statsTracker: ReadingStatsTracker) {
        self.synthesisService = synthesisService
        self.statsTracker = statsTracker
    }

    func isActive(_ ref: ReaderPageRef) -> Bool { activeRef == ref }

    // MARK: - Saved playback (real duration, scrubbing)

    func playSaved(_ ref: ReaderPageRef, project: SavedGeneration, voice: String) {
        stop()
        guard let audio = PageAudioStore.loadAudio(ref, project: project),
            let manifest = PageAudioStore.loadManifest(ref, project: project)
        else { return }
        do {
            let newPlayer = try AVAudioPlayer(data: audio)
            let newDelegate = AudioPlaybackDelegate { [weak self] in
                Task { @MainActor in self?.handleSavedPlaybackFinished() }
            }
            newPlayer.delegate = newDelegate
            player = newPlayer
            delegate = newDelegate
            self.manifest = manifest
            chunkTexts = manifest.chunkTexts
            activeRef = ref
            mode = .saved
            duration = manifest.totalDuration
            elapsed = 0
            currentChunkIndex = 0
            isPlaying = true
            newPlayer.play()
            startTicker()
            statsTracker.beginListening(
                ref: ref, bookTitle: project.title, voice: voice, engine: .kokoroAne)
        } catch {
            resetState()
        }
    }

    private func handleSavedPlaybackFinished() {
        isPlaying = false
        hasFinishedPlayback = true
        elapsed = duration
        currentChunkIndex = max(0, chunkTexts.count - 1)
        statsTracker.endListening(pageCompleted: true)
    }

    /// Where a given chunk starts — the merged file's own offset when
    /// saved, or a running sum of retained chunk durations when streaming;
    /// nil for a chunk streaming hasn't synthesized yet (what keeps tap-
    /// to-seek from jumping ahead of the synthesis frontier).
    func startTime(forChunk index: Int) -> TimeInterval? {
        switch mode {
        case .saved:
            guard let manifest, manifest.chunkStarts.indices.contains(index) else { return nil }
            return manifest.chunkStarts[index]
        case .streaming:
            guard streamingChunkDurations.indices.contains(index) else { return nil }
            return streamingChunkDurations.prefix(index).reduce(0, +)
        case nil:
            return nil
        }
    }

    /// Raw playback position, deliberately NOT `@Published` — for
    /// word-highlighting driven by a `TimelineView` polling ~10-15x/sec in
    /// `ChapterPlayerView`, which needs finer granularity than the 4 Hz
    /// ticker without publishing that often (every view observing this
    /// object would otherwise re-render at that rate — see CLAUDE.md's
    /// re-render rule, the same one that split VoicePreviewPlayer out of
    /// TTSViewModel).
    var currentPlaybackTime: TimeInterval {
        player?.currentTime ?? elapsed
    }

    /// This chunk's word timings — empty if none exist (falls back to
    /// highlighting the whole chunk, as before word-level highlighting;
    /// also what a streaming chunk that hasn't been synthesized yet reads
    /// as, until its turn arrives).
    func wordTimings(forChunk index: Int) -> [WordTiming] {
        switch mode {
        case .saved:
            guard let manifest, manifest.wordTimings.indices.contains(index) else { return [] }
            return manifest.wordTimings[index]
        case .streaming:
            guard streamingWordTimingsStore.indices.contains(index) else { return [] }
            return streamingWordTimingsStore[index]
        case nil:
            return []
        }
    }

    /// The word index within `currentChunkIndex` at `elapsed` — nil for a
    /// chunk with no word timings. `elapsed` here is always chunk-relative
    /// (matches how both modes' `player` is positioned: one merged file
    /// for saved, so the manifest subtracts the chunk's own start offset
    /// internally; one fresh player per chunk for streaming, already
    /// starting at 0, so no offset is needed here).
    func currentWordIndex(atElapsed elapsed: TimeInterval) -> Int? {
        // Playback ended on this chunk's last word, so hold it there rather
        // than resolving a clock that has already reset to 0. Deliberately
        // independent of `elapsed`: saved mode measures it against the merged
        // file while streaming measures it within the chunk, and "the end of
        // the current chunk" is the right answer either way.
        if hasFinishedPlayback {
            let timings = wordTimings(forChunk: currentChunkIndex)
            return timings.isEmpty ? nil : timings.count - 1
        }
        switch mode {
        case .saved:
            guard let manifest else { return nil }
            return manifest.wordIndex(inChunk: currentChunkIndex, atElapsed: elapsed)
        case .streaming:
            let timings = wordTimings(forChunk: currentChunkIndex)
            guard !timings.isEmpty else { return nil }
            var index = 0
            for (i, timing) in timings.enumerated() where timing.start <= elapsed {
                index = i
            }
            return index
        case nil:
            return nil
        }
    }

    func seek(to time: TimeInterval) {
        hasFinishedPlayback = false
        switch mode {
        case .saved:
            guard let player else { return }
            let clamped = max(0, min(time, duration))
            player.currentTime = clamped
            elapsed = clamped
            if let manifest {
                currentChunkIndex = manifest.chunkIndex(atElapsed: clamped)
            }
        case .streaming:
            seekStreaming(to: time)
        case nil:
            return
        }
    }

    func beginScrub() { isScrubbing = true }

    func endScrub(to time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    // seek(to:) already clamps to [0, duration], so skipping past either
    // end just lands on the boundary rather than erroring.
    func skipBackward(by seconds: TimeInterval = 10) {
        seek(to: elapsed - seconds)
    }

    func skipForward(by seconds: TimeInterval = 10) {
        seek(to: elapsed + seconds)
    }

    // MARK: - Streaming playback (synthesize-and-play, chunk by chunk)

    func stream(_ ref: ReaderPageRef, page: ReaderPage, voice: String, bookTitle: String) {
        stop()
        activeRef = ref
        mode = .streaming
        chunkTexts = KokoroTextChunker.chunk(page.text)
        isBuffering = true
        playbackWaitingForIndex = chunkTexts.isEmpty ? nil : 0
        startTicker()
        statsTracker.beginListening(ref: ref, bookTitle: bookTitle, voice: voice, engine: .kokoroAne)

        let chunks = chunkTexts
        streamTask = Task { [weak self] in
            guard let self else { return }
            for (index, chunkText) in chunks.enumerated() {
                guard !Task.isCancelled, self.activeRef == ref else { return }
                do {
                    let (data, wordTimings, chunkDuration) =
                        try await self.synthesisService.synthesizeChunkDetailed(
                            chunkText: chunkText, voice: voice)
                    guard !Task.isCancelled, self.activeRef == ref else { return }
                    self.streamingChunkAudio.append(data)
                    self.streamingWordTimingsStore.append(wordTimings)
                    self.streamingChunkDurations.append(chunkDuration)
                    self.duration += chunkDuration
                    self.handleChunkArrived(index: index)
                } catch {
                    return
                }
            }
        }
    }

    /// Synthesis marches forward independently of playback — this only
    /// starts playback if it was specifically stalled waiting on this
    /// exact chunk (the buffered-mid-chapter case, or chunk 0 at the very
    /// start). If playback is still working through earlier chunks, or the
    /// user has sought elsewhere, this chunk just joins the retained store
    /// for whenever playback gets there.
    private func handleChunkArrived(index: Int) {
        guard playbackWaitingForIndex == index else { return }
        playbackWaitingForIndex = nil
        playFromRetained(index: index, localOffset: 0)
    }

    private func seekStreaming(to time: TimeInterval) {
        hasFinishedPlayback = false
        guard !streamingChunkDurations.isEmpty else { return }
        let clamped = max(0, min(time, duration))
        var cumulative: TimeInterval = 0
        for (index, chunkDuration) in streamingChunkDurations.enumerated() {
            let isLast = index == streamingChunkDurations.count - 1
            if clamped < cumulative + chunkDuration || isLast {
                playbackWaitingForIndex = nil
                playFromRetained(index: index, localOffset: clamped - cumulative)
                elapsed = clamped
                return
            }
            cumulative += chunkDuration
        }
    }

    /// Plays a retained chunk from `localOffset` — used both for normal
    /// forward advancement and for seeking. Explicitly stops any
    /// in-progress player first (rather than just reassigning `player`,
    /// which the old sequential-only design could get away with, since a
    /// seek can now interrupt a chunk mid-playback).
    private func playFromRetained(index: Int, localOffset: TimeInterval) {
        hasFinishedPlayback = false
        guard streamingChunkAudio.indices.contains(index) else { return }
        player?.stop()
        do {
            let newPlayer = try AVAudioPlayer(data: streamingChunkAudio[index])
            newPlayer.currentTime = max(0, min(localOffset, newPlayer.duration))
            let newDelegate = AudioPlaybackDelegate { [weak self] in
                Task { @MainActor in self?.handleStreamingChunkFinished(index: index) }
            }
            newPlayer.delegate = newDelegate
            player = newPlayer
            delegate = newDelegate
            currentChunkIndex = index
            isBuffering = false
            isPlaying = true
            newPlayer.play()
        } catch {
            handleStreamingChunkFinished(index: index)
        }
    }

    // Guarded by index, not just mode: a chunk interrupted by a seek (see
    // playFromRetained) can still fire this stale callback later once its
    // now-orphaned player finishes deallocating — by then currentChunkIndex
    // has already moved on, so the guard below correctly ignores it.
    private func handleStreamingChunkFinished(index: Int) {
        guard mode == .streaming, currentChunkIndex == index else { return }
        let nextIndex = index + 1
        guard nextIndex < chunkTexts.count else {
            isPlaying = false
            hasFinishedPlayback = true
            isBuffering = false
            // Only this branch is a real finish — the one below just
            // advances to the next chunk (mid-page, not done).
            statsTracker.endListening(pageCompleted: true)
            return
        }
        if streamingChunkAudio.indices.contains(nextIndex) {
            playFromRetained(index: nextIndex, localOffset: 0)
        } else {
            isBuffering = true
            playbackWaitingForIndex = nextIndex
        }
    }

    // MARK: - Shared transport

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            statsTracker.pauseListening()
        } else {
            // Tapping play on a finished page restarts it from the top, so
            // the held end-of-chunk highlight has to be released.
            hasFinishedPlayback = false
            player.play()
            isPlaying = true
            statsTracker.resumeListening()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        player?.stop()
        player = nil
        delegate = nil
        // Explicit stop / page change — not a natural finish. No-ops if
        // nothing was active (also covers the natural-finish paths above,
        // which already ended their own session before this ever runs).
        statsTracker.endListening(pageCompleted: false)
        resetState()
    }

    private func resetState() {
        activeRef = nil
        mode = nil
        isPlaying = false
        hasFinishedPlayback = false
        isBuffering = false
        elapsed = 0
        duration = 0
        currentChunkIndex = 0
        manifest = nil
        chunkTexts = []
        streamingChunkAudio = []
        streamingWordTimingsStore = []
        streamingChunkDurations = []
        playbackWaitingForIndex = nil
    }

    // 4 Hz is smooth enough for a scrubber knob and cheap enough not to
    // matter — see VoicePreviewPlayer.startMetering for the same pattern
    // at a faster rate for a different purpose. Runs for both modes now
    // (streaming used to only set elapsed at chunk transitions, which made
    // the scrubber visibly jump once per chunk instead of advancing
    // smoothly within one).
    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let player, isPlaying, !isScrubbing else { return }
        switch mode {
        case .saved:
            elapsed = player.currentTime
            if let manifest {
                currentChunkIndex = manifest.chunkIndex(atElapsed: elapsed)
            }
        case .streaming:
            let priorDuration = streamingChunkDurations.prefix(currentChunkIndex).reduce(0, +)
            elapsed = priorDuration + player.currentTime
        case nil:
            return
        }
    }
}
