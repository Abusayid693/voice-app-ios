import AVFoundation
import Foundation

/// The single owner of every chapter `AVAudioPlayer` in the app — playback
/// is always synthesize-and-play, chunk by chunk; there is no persisted
/// "Generate" path anymore (removed — see CHANGELOG). One object, one
/// `player` field, so "play a different page while this one streams" is
/// just `stop()` then start the new one — the same shape
/// `VoicePreviewPlayer.toggle` already proves correct. Kept off
/// `TTSViewModel` per this app's own re-render rule: the scrubber ticks
/// ~4x/sec, and `TTSViewModel`-observing views (VoicesTabView's grid,
/// voice pickers) shouldn't re-render for that.
///
/// Streaming synthesis is bounded and self-healing, not a one-shot forward
/// march. A single persistent pump task keeps at most
/// `maxSynthesisLookahead` chunks retained ahead of `currentChunkIndex`
/// (`nextSynthesisTarget()`), scanning from the current position every
/// iteration rather than a forward-only cursor — so a tap on any word,
/// synthesized or not, is just "move `currentChunkIndex` there and let the
/// pump notice," whether that's forward past the window, backward into a
/// chunk the pump skipped over on an earlier jump, or a plain resume.
/// Retention is a page-scoped `[Int: RetainedChunk]` dictionary (sparse by
/// construction — a forward jump leaves the skipped indices unfilled on
/// purpose, since they'll never be heard) rather than the append-only
/// arrays this replaced; nothing here assumes "retained" means "a
/// contiguous prefix from 0" the way index-parallel arrays would.
///
/// The same pump also prefetches across a page boundary when continuous
/// playback is enabled: once its lookahead window would run past the
/// current page's last chunk, it starts filling `upcomingPages` (fetched
/// lazily via `nextPageProvider`, which the view supplies since this class
/// has no `LibraryViewModel` of its own). `duration` is therefore an
/// *estimate* of the current page's full length
/// (`synthesizedDurationSoFar ÷ synthesizedCharsSoFar × pageTotalCharacters`,
/// refined as real chunks land), not a running sum of retained audio — a
/// bounded lookahead means that sum would freeze at ~2 chunks' worth and
/// never reflect the page's real length.
@MainActor
final class ChapterAudioPlayer: ObservableObject {
    /// How many chunks may be synthesized ahead of `currentChunkIndex` at
    /// once — spanning a page boundary when continuous playback is on.
    /// Bounded so the ANE idles between chunks instead of running flat out
    /// (see `Features/Chapters/Services/StreamingPlaybackLab.swift`, which
    /// proved this exact shape out first), and so a forward tap doesn't
    /// queue up behind a whole page's worth of marching synthesis in
    /// `ChapterSynthesisService`'s FIFO — with this bound it waits behind
    /// at most one chunk already in flight.
    static let maxSynthesisLookahead = 2

    @Published private(set) var activeRef: ReaderPageRef?
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
    /// An estimate of the current page's full length, not a hard seek
    /// ceiling — see the type's own doc comment. Refined as real chunks
    /// synthesize; approximate before any have.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentChunkIndex = 0
    /// Bumped once per chunk landing (marching, prefetch, or an on-demand
    /// tap target) — what `ChapterPlayerView` listens for to know a
    /// paragraph should upgrade from its plain-text fallback to real word
    /// timings. `duration` alone isn't reliable for this now that it's an
    /// estimate: two different chunk arrivals can occasionally compute the
    /// same estimated total, and SwiftUI's `onChange` only fires on an
    /// actual value change.
    @Published private(set) var synthesisRevision = 0

    /// Read-along text for the streaming chunks as they're known.
    /// Published despite changing rarely: `ChapterPlayerView` derives its
    /// whole paragraph structure from this, and while it was unpublished
    /// that structure only refreshed when some *other* property happened to
    /// publish (the 4 Hz ticker), landing a frame late or not at all.
    @Published private(set) var chunkTexts: [String] = []

    private var player: AVAudioPlayer?
    private var delegate: AudioPlaybackDelegate?
    private var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var isScrubbing = false

    /// One page's worth of synthesized chunks, in-memory for this session
    /// only — nothing is ever written to disk. Keyed by index into
    /// `chunkTexts`, deliberately sparse — see the type's doc comment.
    private struct RetainedChunk {
        let audio: Data
        let wordTimings: [WordTiming]
        let duration: TimeInterval
    }
    private var retainedChunks: [Int: RetainedChunk] = [:]
    /// Set while `playChunk`/`handleStreamingChunkFinished` is waiting on a
    /// specific index the pump hasn't delivered yet; cleared once it lands
    /// (or once playback moves on to something else first).
    private var bufferingForIndex: Int?
    /// Where inside `bufferingForIndex`'s audio to start once it lands — a
    /// specific word (a tap) or a raw offset (an elapsed-time seek landing
    /// in an unsynthesized chunk). Never both; the newer request wins.
    private enum PendingSeek {
        case word(Int)
        case offset(TimeInterval)
    }
    private var pendingSeek: PendingSeek?

    // MARK: - Continuous playback (crossing a page boundary)

    /// Bound to the reader's own preference; read by the pump and by
    /// end-of-page handling. The view is the source of truth for the
    /// setting, so this only ever mirrors it.
    private var continuesToNextPage = false
    /// The player has no `LibraryViewModel` of its own, so the view supplies
    /// how to load a page by index.
    private var nextPageProvider: ((Int) -> ReaderPage?)?
    /// One entry per page fetched ahead of the current one, in order.
    /// Emptied on `stream(...)`/`stop()`; the front entry is consumed by
    /// `promoteNextPage()` when the current page's last chunk finishes.
    private struct UpcomingPage {
        let ref: ReaderPageRef
        let chunkTexts: [String]
        var retained: [Int: RetainedChunk] = [:]
    }
    private var upcomingPages: [UpcomingPage] = []
    /// Latched once `nextPageProvider` says there is no page after the ones
    /// already queued, so the pump stops asking on every poll. Cleared by
    /// `stream(...)`/`resetState()`, i.e. whenever a new page becomes current.
    private var hasReachedEndOfBook = false
    private var activeVoice = ""
    private var activeBookTitle = ""

    // Feed `duration`'s estimate. Reset per page (including on promotion),
    // since a much longer or shorter page would otherwise skew it.
    private var pageTotalCharacters = 0
    private var synthesizedDurationSoFar: TimeInterval = 0
    private var synthesizedCharsSoFar = 0

    private let synthesisService: ChapterSynthesisService
    private let statsTracker: ReadingStatsTracker
    /// Called just before this player starts or resumes audio — wired in
    /// `KokoroAneTestApp` to `BookAudioPlayer.pauseIfPlaying()`, so tapping
    /// play in the reader suspends music mode rather than the two engines
    /// ever sounding at once. See `Features/Listening/`'s mutual-exclusion
    /// note.
    var willStartPlaying: (() -> Void)?
    /// Set while this player has yielded the audio session to music mode
    /// (`pauseIfPlaying`), cleared the next time playback is started or
    /// resumed here. Without it, a chunk that was already in flight when the
    /// yield happened lands in `startPlayer` and resumes reader audio *on
    /// top of* music mode — the pause alone isn't enough, because a player
    /// that was merely buffering had `isPlaying == false` and so nothing for
    /// `pauseIfPlaying` to pause.
    private var isYielded = false

    init(synthesisService: ChapterSynthesisService, statsTracker: ReadingStatsTracker) {
        self.synthesisService = synthesisService
        self.statsTracker = statsTracker
    }

    func isActive(_ ref: ReaderPageRef) -> Bool { activeRef == ref }

    /// Called once by the view (it owns `LibraryViewModel`, this class
    /// doesn't) and whenever the reader's continuous-playback preference
    /// changes. Safe to call at any time, including mid-playback — the pump
    /// reads both on its next iteration.
    func configureContinuousPlayback(
        enabled: Bool, nextPageProvider: @escaping (Int) -> ReaderPage?
    ) {
        continuesToNextPage = enabled
        self.nextPageProvider = nextPageProvider
    }

    func setContinuousPlaybackEnabled(_ enabled: Bool) {
        continuesToNextPage = enabled
    }

    /// Where a given chunk starts — an estimate built from real + estimated
    /// per-chunk durations. Always returns a value for an in-range index:
    /// seeking ahead of the synthesis frontier is exactly what triggers
    /// on-demand synthesis rather than something to guard against.
    func startTime(forChunk index: Int) -> TimeInterval? {
        guard chunkTexts.indices.contains(index) else { return nil }
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { $0 + estimatedDuration(forChunkAt: $1) }
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
    /// also what a chunk that hasn't been synthesized yet reads as, until
    /// its turn arrives).
    func wordTimings(forChunk index: Int) -> [WordTiming] {
        retainedChunks[index]?.wordTimings ?? []
    }

    /// The word index within `currentChunkIndex` at `elapsed` — nil for a
    /// chunk with no word timings. `elapsed` here is always chunk-relative:
    /// one fresh player per chunk, already starting at 0, so no offset is
    /// needed.
    func currentWordIndex(atElapsed elapsed: TimeInterval) -> Int? {
        // Playback ended on this chunk's last word, so hold it there rather
        // than resolving a clock that has already reset to 0.
        if hasFinishedPlayback {
            let timings = wordTimings(forChunk: currentChunkIndex)
            return timings.isEmpty ? nil : timings.count - 1
        }
        let timings = wordTimings(forChunk: currentChunkIndex)
        guard !timings.isEmpty else { return nil }
        var index = 0
        for (i, timing) in timings.enumerated() where timing.start <= elapsed {
            index = i
        }
        return index
    }

    func seek(to time: TimeInterval) {
        hasFinishedPlayback = false
        seekStreaming(to: max(0, time))
    }

    func beginScrub() { isScrubbing = true }

    func endScrub(to time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    func skipBackward(by seconds: TimeInterval = 10) {
        seek(to: elapsed - seconds)
    }

    func skipForward(by seconds: TimeInterval = 10) {
        seek(to: elapsed + seconds)
    }

    // MARK: - Streaming playback (synthesize-and-play, chunk by chunk)

    /// Starts (or restarts) streaming a page, optionally targeting a
    /// specific chunk/word rather than the beginning — the same entry
    /// point serves a plain Play tap (`startingAt: 0`) and "Play from
    /// here" on a page that wasn't active yet.
    func stream(
        _ ref: ReaderPageRef, page: ReaderPage, voice: String, bookTitle: String,
        startingAt startIndex: Int = 0, wordIndex: Int? = nil
    ) {
        willStartPlaying?()
        isYielded = false
        stop()
        activeRef = ref
        activeVoice = voice
        activeBookTitle = bookTitle
        chunkTexts = KokoroTextChunker.chunk(page.text)
        pageTotalCharacters = chunkTexts.reduce(0) { $0 + $1.count }
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        retainedChunks = [:]
        upcomingPages = []
        hasReachedEndOfBook = false
        duration = 0
        startTicker()
        statsTracker.beginListening(ref: ref, bookTitle: bookTitle, voice: voice, engine: .kokoroAne)
        guard !chunkTexts.isEmpty else { return }
        let clampedStart = chunkTexts.indices.contains(startIndex) ? startIndex : 0
        currentChunkIndex = clampedStart
        isBuffering = true
        bufferingForIndex = clampedStart
        pendingSeek = wordIndex.map(PendingSeek.word)
        startPump()
    }

    /// The entry point behind "Play from here": redirects the already-active
    /// pump to this chunk, or starts fresh targeting it directly.
    func playFromWord(
        ref: ReaderPageRef, page: ReaderPage,
        chunkIndex: Int, wordIndex: Int?, voice: String, bookTitle: String
    ) {
        if activeRef == ref {
            playChunk(chunkIndex, wordIndex: wordIndex)
        } else {
            stream(
                ref, page: page, voice: voice, bookTitle: bookTitle,
                startingAt: chunkIndex, wordIndex: wordIndex)
        }
    }

    /// Moves playback to `index` — playing immediately if it's retained,
    /// otherwise marking it as what the pump should prioritize next.
    /// Publishing `currentChunkIndex` before checking retention is what
    /// makes this the single mechanism behind a forward tap past the
    /// window, a backward tap into a chunk an earlier jump skipped over,
    /// and an elapsed-time seek landing in an unsynthesized chunk — the
    /// pump's own target selection always scans from `currentChunkIndex`,
    /// never a forward-only cursor, so any of those just fall out of
    /// setting this one property.
    private func playChunk(_ index: Int, wordIndex: Int? = nil, localOffsetOverride: TimeInterval? = nil) {
        guard chunkTexts.indices.contains(index) else { return }
        hasFinishedPlayback = false
        currentChunkIndex = index
        if let retained = retainedChunks[index] {
            let localOffset =
                localOffsetOverride
                ?? (wordIndex.flatMap { wordIndex in
                    retained.wordTimings.indices.contains(wordIndex)
                        ? retained.wordTimings[wordIndex].start : nil
                } ?? 0)
            bufferingForIndex = nil
            pendingSeek = nil
            startPlayer(audio: retained.audio, index: index, localOffset: localOffset)
        } else {
            // Stop what's playing *now*, not when the new chunk lands. The
            // old player is otherwise still running against a passage the
            // user has just moved away from, and `handleStreamingChunkFinished`
            // won't advance it either (its `currentChunkIndex == index` guard
            // no longer matches), so it would read on for up to a whole
            // chunk before the new one interrupts it.
            player?.stop()
            player = nil
            delegate = nil
            isPlaying = false
            isBuffering = true
            bufferingForIndex = index
            pendingSeek = localOffsetOverride.map(PendingSeek.offset) ?? wordIndex.map(PendingSeek.word)
        }
    }

    private func seekStreaming(to time: TimeInterval) {
        hasFinishedPlayback = false
        guard !chunkTexts.isEmpty else { return }
        var cumulative: TimeInterval = 0
        for index in chunkTexts.indices {
            let chunkDuration = estimatedDuration(forChunkAt: index)
            let isLast = index == chunkTexts.count - 1
            if time < cumulative + chunkDuration || isLast {
                playChunk(index, localOffsetOverride: max(0, time - cumulative))
                return
            }
            cumulative += chunkDuration
        }
    }

    /// Plays a chunk's audio from `localOffset`. Sets `currentChunkIndex`
    /// as the very first thing, before anything that can throw — a decode
    /// failure used to fall into `handleStreamingChunkFinished` while the
    /// index was still stale, so that handler's own `currentChunkIndex ==
    /// index` guard silently rejected it and the chain froze.
    private func startPlayer(audio: Data, index: Int, localOffset: TimeInterval) {
        currentChunkIndex = index
        player?.stop()
        do {
            let newPlayer = try AVAudioPlayer(data: audio)
            newPlayer.currentTime = max(0, min(localOffset, newPlayer.duration))
            let newDelegate = AudioPlaybackDelegate { [weak self] in
                Task { @MainActor in self?.handleStreamingChunkFinished(index: index) }
            }
            newPlayer.delegate = newDelegate
            player = newPlayer
            delegate = newDelegate
            isBuffering = false
            bufferingForIndex = nil
            // Prepared at the right offset but deliberately not started:
            // music mode owns the audio right now, and resuming here would
            // put both engines through the speaker at once. A later resume
            // plays this same prepared player from where it was left.
            guard !isYielded else {
                isPlaying = false
                return
            }
            isPlaying = true
            newPlayer.play()
        } catch {
            handleStreamingChunkFinished(index: index)
        }
    }

    // Guarded by index, not just mode: a chunk interrupted by a seek (see
    // startPlayer) can still fire this stale callback later once its
    // now-orphaned player finishes deallocating — by then currentChunkIndex
    // has already moved on, so the guard below correctly ignores it.
    private func handleStreamingChunkFinished(index: Int) {
        guard activeRef != nil, currentChunkIndex == index else { return }
        let nextIndex = index + 1
        if nextIndex < chunkTexts.count {
            playChunk(nextIndex)
            return
        }

        // End of this page's chunks.
        guard continuesToNextPage, let ref = activeRef else {
            isPlaying = false
            hasFinishedPlayback = true
            isBuffering = false
            statsTracker.endListening(pageCompleted: true)
            return
        }
        // Normally already prefetched by the pump; this is the just-in-time
        // fallback for a page too short for the lookahead to have kicked in
        // yet, or the preference having been enabled only just now.
        if upcomingPages.isEmpty {
            guard let page = nextPageProvider?(ref.pageIndex + 1) else {
                isPlaying = false
                hasFinishedPlayback = true
                isBuffering = false
                statsTracker.endListening(pageCompleted: true)
                return
            }
            let newRef = ReaderPageRef(projectID: ref.projectID, pageIndex: ref.pageIndex + 1)
            upcomingPages = [
                UpcomingPage(ref: newRef, chunkTexts: KokoroTextChunker.chunk(page.text))
            ]
        }
        statsTracker.endListening(pageCompleted: true)
        promoteNextPage()
    }

    /// Swaps in the prefetched next page and keeps playing — deliberately
    /// not routed through `stop()`/`resetState()`, which would end the
    /// session this is trying to continue.
    private func promoteNextPage() {
        // Skip a genuinely blank page rather than promoting into one:
        // chunkTexts.isEmpty means playChunk(0) below would silently no-op
        // (nothing to play, no player, no callback ever scheduled), leaving
        // isPlaying stuck true with nothing actually happening.
        while let candidate = upcomingPages.first, candidate.chunkTexts.isEmpty {
            upcomingPages.removeFirst()
        }
        guard !upcomingPages.isEmpty else {
            // Every already-fetched upcoming page was blank. Rare (the
            // pump only prefetches 1-2 pages ahead), and the same terminal
            // state handleStreamingChunkFinished uses when there's no
            // continuation at all — stopping cleanly beats getting stuck.
            isPlaying = false
            hasFinishedPlayback = true
            isBuffering = false
            return
        }
        let promoted = upcomingPages.removeFirst()
        // A page just became current, so "no page after the queued ones" is
        // a stale answer — there may be one after *this* one.
        hasReachedEndOfBook = false
        activeRef = promoted.ref
        chunkTexts = promoted.chunkTexts
        retainedChunks = promoted.retained
        pageTotalCharacters = promoted.chunkTexts.reduce(0) { $0 + $1.count }
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        for (index, retained) in promoted.retained where promoted.chunkTexts.indices.contains(index) {
            synthesizedDurationSoFar += retained.duration
            synthesizedCharsSoFar += promoted.chunkTexts[index].count
        }
        refreshDurationEstimate()
        elapsed = 0
        hasFinishedPlayback = false
        statsTracker.beginListening(
            ref: promoted.ref, bookTitle: activeBookTitle, voice: activeVoice, engine: .kokoroAne)
        playChunk(0)
    }

    // MARK: - Synthesis pump

    /// Where the next synthesis request should go, scanning from
    /// `currentChunkIndex` every call rather than tracking a forward-only
    /// cursor — see the type's doc comment for why that self-healing
    /// property is what makes a jump in either direction "just work."
    private enum SynthesisTarget {
        case current(Int)
        case upcoming(pageOffset: Int, chunkIndex: Int)
    }

    private func nextSynthesisTarget() -> SynthesisTarget? {
        guard activeRef != nil else { return nil }
        let upper = currentChunkIndex + Self.maxSynthesisLookahead
        for index in currentChunkIndex...upper where chunkTexts.indices.contains(index) {
            if retainedChunks[index] == nil { return .current(index) }
        }
        guard continuesToNextPage, upper >= chunkTexts.count - 1 else { return nil }
        var remaining = upper - (chunkTexts.count - 1)
        guard remaining > 0 else { return nil }

        // The provider reads a page off disk and decodes it, and this runs on
        // the main actor every time the pump polls (~5Hz). Without this the
        // last page of a book asks for a page that doesn't exist, over and
        // over, for as long as it plays.
        guard !hasReachedEndOfBook else { return nil }

        var pageOffset = 0
        while true {
            if pageOffset >= upcomingPages.count {
                guard let ref = activeRef else { return nil }
                let candidatePageIndex = ref.pageIndex + 1 + upcomingPages.count
                guard let page = nextPageProvider?(candidatePageIndex) else {
                    hasReachedEndOfBook = true
                    return nil
                }
                let newRef = ReaderPageRef(projectID: ref.projectID, pageIndex: candidatePageIndex)
                upcomingPages.append(
                    UpcomingPage(ref: newRef, chunkTexts: KokoroTextChunker.chunk(page.text)))
            }
            let texts = upcomingPages[pageOffset].chunkTexts
            guard !texts.isEmpty else {
                pageOffset += 1
                continue
            }
            let budget = min(texts.count, remaining)
            for localIndex in 0..<budget
            where upcomingPages[pageOffset].retained[localIndex] == nil {
                return .upcoming(pageOffset: pageOffset, chunkIndex: localIndex)
            }
            remaining -= budget
            guard remaining > 0 else { return nil }
            pageOffset += 1
        }
    }

    private func synthesizeAndRetain(_ target: SynthesisTarget) async throws {
        switch target {
        case .current(let index):
            guard chunkTexts.indices.contains(index) else { return }
            let text = chunkTexts[index]
            let (data, wordTimings, chunkDuration) =
                try await synthesisService.synthesizeChunkDetailed(chunkText: text, voice: activeVoice)
            // The page could have changed under us while this was in
            // flight (a manual page change stops the player entirely, but
            // guard anyway rather than trusting timing).
            guard activeRef != nil, chunkTexts.indices.contains(index), chunkTexts[index] == text
            else { return }
            retainedChunks[index] = RetainedChunk(
                audio: data, wordTimings: wordTimings, duration: chunkDuration)
            synthesizedDurationSoFar += chunkDuration
            synthesizedCharsSoFar += text.count
            refreshDurationEstimate()
            synthesisRevision += 1
            if bufferingForIndex == index {
                bufferingForIndex = nil
                let localOffset = resolvedPendingOffset(wordTimings: wordTimings)
                pendingSeek = nil
                startPlayer(audio: data, index: index, localOffset: localOffset)
            }
        case .upcoming(let pageOffset, let chunkIndex):
            guard upcomingPages.indices.contains(pageOffset),
                upcomingPages[pageOffset].chunkTexts.indices.contains(chunkIndex)
            else { return }
            let text = upcomingPages[pageOffset].chunkTexts[chunkIndex]
            let (data, wordTimings, chunkDuration) =
                try await synthesisService.synthesizeChunkDetailed(chunkText: text, voice: activeVoice)
            // Promotion can shift/empty `upcomingPages` while this was in
            // flight; re-validate rather than trusting the captured offset.
            guard upcomingPages.indices.contains(pageOffset),
                upcomingPages[pageOffset].chunkTexts.indices.contains(chunkIndex),
                upcomingPages[pageOffset].chunkTexts[chunkIndex] == text
            else { return }
            upcomingPages[pageOffset].retained[chunkIndex] = RetainedChunk(
                audio: data, wordTimings: wordTimings, duration: chunkDuration)
            // Deliberately no `synthesisRevision` bump: this chunk belongs to
            // a page that isn't displayed, and the revision exists to tell
            // the *current* page's paragraphs to pick up real word timings.
        }
    }

    private func resolvedPendingOffset(wordTimings: [WordTiming]) -> TimeInterval {
        switch pendingSeek {
        case .word(let index):
            return wordTimings.indices.contains(index) ? wordTimings[index].start : 0
        case .offset(let value):
            return value
        case nil:
            return 0
        }
    }

    /// One persistent task for the whole streaming session — including
    /// across page promotions, which is why it's started once in
    /// `stream(...)` and never restarted on its own. Polling rather than a
    /// wake signal, the same shape `StreamingPlaybackLab.pumpChunks` proved
    /// out: a page's worth of chunks is a small, cheap thing to re-scan.
    private func startPump() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let target = self.nextSynthesisTarget() else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                do {
                    try await self.synthesizeAndRetain(target)
                } catch {
                    // Don't spin hot on a persistent failure (e.g. a voice
                    // pack that's gone missing mid-session).
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    private func estimatedDuration(forChunkAt index: Int) -> TimeInterval {
        if let retained = retainedChunks[index] { return retained.duration }
        guard chunkTexts.indices.contains(index), synthesizedCharsSoFar > 0 else { return 0 }
        let perCharacter = synthesizedDurationSoFar / Double(synthesizedCharsSoFar)
        return perCharacter * Double(chunkTexts[index].count)
    }

    private func refreshDurationEstimate() {
        guard synthesizedCharsSoFar > 0, pageTotalCharacters > 0 else { return }
        duration =
            synthesizedDurationSoFar / Double(synthesizedCharsSoFar) * Double(pageTotalCharacters)
    }

    // MARK: - Shared transport

    /// Pauses without stopping — the yield half of read-along/music mode's
    /// mutual exclusion (see `Features/Listening/ViewModels/BookAudioPlayer.swift`).
    /// `stop()` would end the stats session and discard retained chunks;
    /// this keeps both intact so resuming here is instant.
    func pauseIfPlaying() {
        isYielded = true
        guard isPlaying else { return }
        togglePlayPause()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            statsTracker.pauseListening()
        } else {
            willStartPlaying?()
            isYielded = false
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
        isPlaying = false
        hasFinishedPlayback = false
        isBuffering = false
        elapsed = 0
        duration = 0
        currentChunkIndex = 0
        chunkTexts = []
        retainedChunks = [:]
        upcomingPages = []
        hasReachedEndOfBook = false
        bufferingForIndex = nil
        pendingSeek = nil
        pageTotalCharacters = 0
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        // continuesToNextPage/nextPageProvider/activeVoice/activeBookTitle
        // deliberately survive a stop(): the first two are session
        // configuration the view sets once, not per-play state, and the
        // latter two are overwritten by the next stream() call.
    }

    // 4 Hz is smooth enough for a scrubber knob and cheap enough not to
    // matter — see VoicePreviewPlayer.startMetering for the same pattern
    // at a faster rate for a different purpose.
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
        let priorDuration =
            currentChunkIndex > 0
            ? (0..<currentChunkIndex).reduce(0.0) { $0 + estimatedDuration(forChunkAt: $1) } : 0
        elapsed = priorDuration + player.currentTime
    }
}
