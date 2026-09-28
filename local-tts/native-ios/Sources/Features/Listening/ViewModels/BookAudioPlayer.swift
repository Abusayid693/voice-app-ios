import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// The app's single playback owner: one book, one audio session, two
/// interchangeable views. `ChapterPlayerView` renders it either as
/// read-along text with chunk and word highlighting or as a music-style
/// now-playing screen — switching between them is a view change only,
/// never a playback change. Supersedes the two-engine split
/// `docs/adr/0012-two-playback-engines.md` accepted; see
/// `docs/adr/0013-unified-player.md`.
///
/// The engine came from `StreamingPlaybackLab` (`Features/Chapters/
/// Services/StreamingPlaybackLab.swift`): one `AVAudioPlayerNode` with
/// buffers scheduled onto it, gapless, plus a silence keep-alive so a slow
/// synthesis stretch can't leave the node silent long enough for iOS to
/// suspend the app (once suspended, synthesis stops too, and it never
/// recovers). The page model — bounded lookahead, cross-page prefetch,
/// position and stats — came from the `ChapterAudioPlayer` this replaced.
///
/// **Scheduling vs. synthesis are two separate cursors.** A node's queue is
/// strictly ordered — buffers can't be reordered or inserted once scheduled
/// — so this retains a *whole page's* chunks (small: a page is ≤2,000
/// words, a handful of ~350-char chunks) rather than evicting, and keeps
/// `scheduleCursor` (what's been handed to the node, in order) separate
/// from the self-healing synthesis scan (what's been *retained*, which may
/// land out of order within the lookahead window). Seeking flushes the
/// queue (`node.stop()`) and restarts `scheduleCursor` from the target — a
/// retained chunk schedules immediately, sliced to the right frame offset
/// for an intra-chunk seek; one that isn't triggers synthesis first.
///
/// **Position comes from the node's own render clock**, mapped through
/// `scheduledSpans` — see `resolvedPosition()`. There is no
/// `AVAudioPlayer.currentTime` equivalent on a node, and the wall clock
/// this replaced was both the wrong shape (page-relative, where word
/// timings are chunk-relative) and inexact: it counted silence keep-alive
/// buffers as spoken time, so the position slid ahead of the audio after
/// any starvation and never came back.
@MainActor
final class BookAudioPlayer: ObservableObject {
    /// Keeps the ANE idling between chunks rather than running flat out,
    /// and caps how long a seek can wait behind synthesis already in
    /// flight — `ChapterSynthesisService.runSerially` is a FIFO with no
    /// priority lane, so an unbounded march would queue a seek behind a
    /// whole page of synthesis.
    static let maxSynthesisLookahead = 2

    @Published private(set) var activeRef: ReaderPageRef?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// Elapsed within the *current page*, derived from the node's own render
    /// clock via `scheduledSpans` — what the draggable page scrubber binds
    /// to. Republished by the 1Hz ticker, which is plenty for a scrubber;
    /// the read-along's word highlighting polls `currentWordIndex()` at
    /// ~12Hz instead, deliberately unpublished — publishing at that rate
    /// would re-render every view observing this object (CLAUDE.md's
    /// re-render rule).
    @Published private(set) var elapsed: TimeInterval = 0
    /// Estimated length of the current page, refined as real chunks land.
    /// An estimate rather than a running sum of retained audio because
    /// bounded lookahead would freeze that sum at ~2 chunks' worth.
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var bookTitle = ""
    @Published private(set) var coverURL: URL?
    /// Whole-book fraction, `(pageIndex + fractionOfCurrentPage) / pageCount`
    /// — the non-draggable book-wide bar. No total-character scan of every
    /// page file; it only ever needs this page's own progress plus counts
    /// already on hand.
    @Published private(set) var bookProgress: Double = 0
    /// Timestamped trace, same idea as the lab's — the thermal/throughput
    /// question ("can synthesis stay ahead while locked?") is answered by
    /// reading this after a long locked-screen run, not by guessing.
    @Published private(set) var events: [String] = []

    /// The current page's chunk texts — the source `ChapterPlayerView`
    /// derives its entire paragraph structure from. Published despite
    /// changing rarely: while it was unpublished, that structure only
    /// refreshed when some *other* property happened to publish, landing a
    /// frame late or not at all.
    @Published private(set) var chunkTexts: [String] = []
    /// Which chunk is **sounding**, resolved from the node's render clock
    /// rather than from the completion callback (which reports what has
    /// *finished*). Drives the read-along's chunk highlight, so resolving it
    /// from the clock removes the callback-latency lag the per-chunk
    /// `AVAudioPlayer` design used to have.
    @Published private(set) var currentChunkIndex = 0
    /// Bumped once per chunk landing for the *current* page only (never for
    /// next-page prefetch, which would make the displayed page recompute its
    /// words for audio it isn't showing). `ChapterPlayerView` watches this
    /// rather than `duration` to upgrade paragraphs from their plain-text
    /// fallback to real word timings — `duration` is an estimate that can
    /// compute the same value twice, and `onChange` only fires on a real
    /// change.
    @Published private(set) var synthesisRevision = 0

    private let synthesis: ChapterSynthesisService
    private let statsTracker: ReadingStatsTracker

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var isConnected = false
    /// Whether `node` is currently attached to `engine`. Tracked separately
    /// from `isConnected`, which only turns true once a buffer has actually
    /// been scheduled: attach/detach has to balance on its own terms.
    /// `detach` used to be conditional on `isConnected`, so a session
    /// started and abandoned before its first chunk landed left the node
    /// attached while `isConnected` read false — and the next `start()`
    /// attached the same node to the same engine a second time. Whether
    /// AVAudioEngine tolerates that is undocumented either way; leaving the
    /// engine owning a node nothing releases is wrong regardless.
    private var isAttached = false
    private var format: AVAudioFormat?
    private var isFinishedBook = false
    private var observers: [NSObjectProtocol] = []
    private var startedAt = Date()
    private var pump: Task<Void, Never>?
    private var ticker: Timer?

    /// Buffers scheduled on the node but not yet played out — zero means
    /// the node is about to fall silent. See `scheduleSilence()`.
    private var pendingBuffers = 0
    /// Bumped whenever the node's queue is invalidated (a seek's flush, a
    /// page change). Every scheduled buffer's completion closure captures
    /// the epoch it was scheduled under and does nothing if it no longer
    /// matches. `AVAudioPlayerNode` calls completion handlers for buffers it
    /// *discards* on `stop()`, not only for ones it finished playing, so
    /// without this a flushed buffer's late callback is indistinguishable
    /// from a real one — and comparing chunk indices alone isn't enough,
    /// since seeking *within* the same chunk leaves the index unchanged and
    /// would spuriously advance the page (marking it complete, at the end
    /// of one) off a buffer that never actually played.
    private var playbackEpoch = 0
    /// Whether `node.play()` is currently in effect — deliberately separate
    /// from the published `isPlaying`, which is user-facing intent. `stop()`
    /// on the node (what a seek's flush does) halts rendering, so the node
    /// has to be told to play again afterwards; keying that off `isPlaying`
    /// meant a seek mid-playback left `isPlaying == true` with a stopped
    /// node, i.e. silence the UI still reported as playing.
    private var isNodeRunning = false
    /// True only after an explicit pause (the user, an interruption, or a
    /// route change), as opposed to "hasn't started yet". A chunk landing
    /// must auto-start playback in the second case but must *not* resume it
    /// in the first, or an arriving chunk resumes audio on its own.
    private var isUserPaused = false

    private var projectID: UUID?
    private var voice = ""
    /// The player has no `LibraryViewModel` of its own — the caller (see
    /// `ImportHomeView`'s `startListening`) supplies both. `positionWriter`
    /// is what makes read-along and music mode share one `lastReadPageIndex`
    /// — `ChapterPlayerView` calls the same `LibraryViewModel.
    /// recordLastReadPage` itself; this player has to be handed the call
    /// since it isn't a view.
    private var pageProvider: ((Int) -> ReaderPage?)?
    private var positionWriter: ((Int) -> Void)?

    private struct RetainedChunk {
        let samples: [Float]
        let sampleRate: Int
        let duration: TimeInterval
        /// Empty for non-English voices (no alignment path) and for a chunk
        /// not yet synthesized — both fall back to chunk-level highlighting,
        /// exactly as the reader has always done.
        let wordTimings: [WordTiming]
    }
    private var retainedChunks: [Int: RetainedChunk] = [:]
    /// Index into `chunkTexts` of the chunk playback is *on* — advanced by
    /// the node's completion callback, and what the self-healing synthesis
    /// scan and every seek read from. Distinct from the published
    /// `currentChunkIndex`, which the render clock resolves for the UI:
    /// this one is scheduling bookkeeping, that one is what you can hear.
    private var playingChunk = 0
    /// Index into `chunkTexts` of the next chunk to *schedule* on the node —
    /// distinct from `playingChunk` because the node's queue is strictly
    /// ordered and can only ever be appended to, never reordered. Advances
    /// only when the chunk at this index is retained; see `scheduleReady()`.
    private var scheduleCursor = 0
    /// Frame offset to slice the very next chunk `scheduleCursor` points at
    /// — non-zero only right after a seek lands mid-chunk. Consumed once.
    private var scheduleCursorFrameOffset = 0
    private var bufferingForIndex: Int?
    private var pendingSeekOffset: TimeInterval?
    /// A word target waiting on the chunk that contains it — "play from
    /// here" on text whose timings don't exist yet, which is exactly the
    /// case tapping ahead is for. Resolved to a real offset the moment the
    /// chunk lands; never set at the same time as `pendingSeekOffset`.
    private var pendingSeekWord: Int?
    /// The reader's "Continue to next page" preference, mirrored here.
    /// Music mode always wants it; read-along lets the user turn it off.
    private var continuesToNextPage = true

    private struct UpcomingPage {
        let ref: ReaderPageRef
        let chunkTexts: [String]
        var retained: [Int: RetainedChunk] = [:]
    }
    private var upcomingPages: [UpcomingPage] = []
    private var hasReachedEndOfBook = false

    private var pageTotalCharacters = 0
    private var synthesizedDurationSoFar: TimeInterval = 0
    private var synthesizedCharsSoFar = 0

    /// One entry per buffer handed to the node since the last flush, in
    /// play order — the map that turns the node's render clock into "which
    /// chunk, and how far into it". `AVAudioPlayerNode` has no
    /// `AVAudioPlayer.currentTime` equivalent, and the wall clock this
    /// replaced was both the wrong shape (page-relative, where word timings
    /// are chunk-relative) and inexact: it counted silence keep-alive
    /// buffers as elapsed speech, so the position slid ahead of the audio
    /// after any starvation and never recovered.
    private struct ScheduledSpan {
        let startSample: AVAudioFramePosition
        let frameCount: AVAudioFramePosition
        let chunkIndex: Int
        /// Silence holds the position at the previous speech span's end
        /// rather than advancing through it — see `resolvedPosition()`.
        let isSilence: Bool
        /// Where in the chunk this span begins; non-zero for the sliced
        /// first buffer after a mid-chunk seek.
        let chunkOffset: TimeInterval
    }
    private var scheduledSpans: [ScheduledSpan] = []
    /// Running total of frames scheduled since the last flush — the next
    /// span's `startSample`. `node.stop()` resets the node's own sample
    /// clock to zero, and every flush bumps `playbackEpoch`, so this resets
    /// at exactly the same moment.
    private var scheduledFrames: AVAudioFramePosition = 0
    /// Last position the clock successfully resolved. `lastRenderTime` is
    /// nil whenever the node isn't rendering (paused, stopped, engine down),
    /// so the position has to be held rather than collapsing to zero.
    private var lastResolvedPosition: (chunkIndex: Int, offset: TimeInterval) = (0, 0)
    private var isScrubbing = false

    private var artwork: MPMediaItemArtwork?

    init(synthesis: ChapterSynthesisService, statsTracker: ReadingStatsTracker) {
        self.synthesis = synthesis
        self.statsTracker = statsTracker
    }

    func isActive(_ ref: ReaderPageRef) -> Bool { activeRef == ref }

    // MARK: - Control

    /// Starts (or restarts) playback of a book at `startIndex`, optionally
    /// targeting a chunk/word rather than the page's beginning — the same
    /// entry point serves a plain Play tap, the shelf's Listen button, and
    /// "Play from here" on a page that wasn't active yet.
    ///
    /// `voice` is passed explicitly rather than read off `project`: the
    /// reader's own selection is the fresher value, since `changeVoice`
    /// persists to disk while whatever `SavedGeneration` the caller is
    /// holding stays as it was when the screen was pushed.
    func start(
        project: SavedGeneration, page: ReaderPage, startIndex: Int, voice: String,
        startingAtChunk: Int = 0, wordIndex: Int? = nil,
        pageProvider: @escaping (Int) -> ReaderPage?,
        positionWriter: @escaping (Int) -> Void
    ) {
        stop()

        projectID = project.id
        self.voice = voice
        bookTitle = project.title
        coverURL = SavedGeneration.existingCoverURL(id: project.id)
        pageCount = project.pageCount
        self.pageProvider = pageProvider
        self.positionWriter = positionWriter
        artwork = Self.loadArtwork(url: coverURL)

        do {
            try activateSession()
        } catch {
            log("Audio session failed: \(error.localizedDescription)")
            return
        }
        configureRemoteCommands()
        observeSystemEvents()
        if !isAttached {
            engine.attach(node)
            isAttached = true
        }
        startedAt = Date()
        isFinishedBook = false

        beginPage(
            ref: ReaderPageRef(projectID: project.id, pageIndex: startIndex), page: page,
            startingAtChunk: startingAtChunk, wordIndex: wordIndex)
        log("start: \(bookTitle), page \(startIndex + 1) of \(pageCount)")
        startPump()
        startTicker()
    }

    /// "Play from here" — redirects the already-running player to this
    /// chunk/word, or starts fresh targeting it when this page isn't the
    /// active one.
    func playFromWord(
        project: SavedGeneration, page: ReaderPage, pageIndex: Int, voice: String,
        chunkIndex: Int, wordIndex: Int?,
        pageProvider: @escaping (Int) -> ReaderPage?,
        positionWriter: @escaping (Int) -> Void
    ) {
        let ref = ReaderPageRef(projectID: project.id, pageIndex: pageIndex)
        guard activeRef == ref else {
            start(
                project: project, page: page, startIndex: pageIndex, voice: voice,
                startingAtChunk: chunkIndex, wordIndex: wordIndex,
                pageProvider: pageProvider, positionWriter: positionWriter)
            return
        }
        seekToChunk(chunkIndex, offset: 0, wordIndex: wordIndex)
    }

    /// Called by the reader once on appear and whenever its
    /// continuous-playback preference changes. Safe at any time — the pump
    /// reads both on its next iteration.
    func configureContinuousPlayback(
        enabled: Bool, nextPageProvider: @escaping (Int) -> ReaderPage?
    ) {
        continuesToNextPage = enabled
        pageProvider = nextPageProvider
    }

    func setContinuousPlaybackEnabled(_ enabled: Bool) {
        continuesToNextPage = enabled
    }

    /// Works before the first chunk has landed too — pausing while the
    /// opening chunk is still synthesizing latches `isUserPaused` so that
    /// chunk schedules without starting playback, rather than the button
    /// sitting dead for the first few seconds of a session.
    func togglePlayPause() {
        guard activeRef != nil else { return }
        if isPlaying || (!isUserPaused && !isConnected) {
            if isNodeRunning {
                // Resolve before pausing: `lastRenderTime` goes nil once the
                // node stops rendering, and this is what the clock holds at
                // for the duration of the pause.
                _ = resolvedPosition()
                pauseEngine()
            }
            isUserPaused = true
            isPlaying = false
            statsTracker.pauseListening()
        } else {
            isUserPaused = false
            // Nothing scheduled yet (paused through the initial buffer, or
            // resumed after a seek that's still waiting on synthesis) —
            // `schedule()` starts the node as soon as a buffer lands.
            if isConnected, pendingBuffers > 0 {
                startNodeIfNeeded()
                isPlaying = true
            }
            statsTracker.resumeListening()
        }
        updateNowPlaying()
    }

    /// Starts the node, restarting the engine first if a pause stopped it.
    ///
    /// **Pausing has to stop the engine, not just the node.** On iOS the
    /// Now Playing state is derived from the app's audio session — see
    /// `MPNowPlayingInfoCenter.playbackState`, whose own header says it
    /// "only applies on macOS, where playback state cannot be determined by
    /// the application's audio session". Pausing the player node alone
    /// leaves the engine running and the session live, so iOS keeps showing
    /// the app as playing however the now-playing dictionary is posted, and
    /// the lock screen's button stops following in-app play/pause.
    private func startNodeIfNeeded() {
        guard isConnected, !isNodeRunning else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                log("engine restart failed: \(error.localizedDescription)")
                return
            }
        }
        node.play()
        isNodeRunning = true
    }

    private func pauseEngine() {
        node.pause()
        engine.pause()
        isNodeRunning = false
    }

    func stop() {
        pump?.cancel()
        pump = nil
        removeObservers()
        ticker?.invalidate()
        ticker = nil
        pendingBuffers = 0
        playbackEpoch += 1
        isNodeRunning = false
        isUserPaused = false
        format = nil
        isFinishedBook = false
        if isConnected {
            node.stop()
            engine.stop()
            isConnected = false
            // Only release the session when something actually played —
            // deactivating one we never used would tell other apps a
            // playback session just ended when none had begun.
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        }
        if isAttached {
            engine.detach(node)
            isAttached = false
        }
        MPRemoteCommandCenter.shared().playCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().pauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().skipForwardCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().skipBackwardCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().nextTrackCommand.removeTarget(nil)
        MPRemoteCommandCenter.shared().previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        statsTracker.endListening(pageCompleted: false)

        activeRef = nil
        isPlaying = false
        isBuffering = false
        elapsed = 0
        duration = 0
        pageIndex = 0
        pageCount = 0
        bookProgress = 0
        bookTitle = ""
        coverURL = nil
        artwork = nil
        projectID = nil
        voice = ""
        pageProvider = nil
        positionWriter = nil
        chunkTexts = []
        retainedChunks = [:]
        playingChunk = 0
        scheduleCursor = 0
        scheduleCursorFrameOffset = 0
        bufferingForIndex = nil
        pendingSeekOffset = nil
        pendingSeekWord = nil
        upcomingPages = []
        hasReachedEndOfBook = false
        pageTotalCharacters = 0
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        scheduledSpans = []
        scheduledFrames = 0
        lastResolvedPosition = (0, 0)
        currentChunkIndex = 0
        chunkTexts = []
        synthesisRevision = 0
    }

    // MARK: - Seek

    func beginScrub() { isScrubbing = true }

    func endScrub(to time: TimeInterval) {
        isScrubbing = false
        seek(to: time)
    }

    func skipBackward(by seconds: TimeInterval = 15) {
        seek(to: elapsedNow() - seconds)
    }

    func skipForward(by seconds: TimeInterval = 15) {
        seek(to: elapsedNow() + seconds)
    }

    /// Seeks within the *current page* — the scrubber is deliberately
    /// page-scoped, not whole-book (see the plan this shipped from): a
    /// whole-book seek could drop onto an unsynthesized page far from the
    /// lookahead window, with nothing bounding how long that buffers for.
    func seek(to time: TimeInterval) {
        guard !chunkTexts.isEmpty else { return }
        let clamped = max(0, time)
        var cumulative: TimeInterval = 0
        for index in chunkTexts.indices {
            let chunkDuration = estimatedDuration(forChunkAt: index)
            let isLast = index == chunkTexts.count - 1
            if clamped < cumulative + chunkDuration || isLast {
                seekToChunk(index, offset: max(0, clamped - cumulative))
                return
            }
            cumulative += chunkDuration
        }
    }

    private func seekToChunk(_ index: Int, offset: TimeInterval, wordIndex: Int? = nil) {
        guard chunkTexts.indices.contains(index) else { return }
        flushNode()
        playingChunk = index
        scheduleCursor = index
        // A word target resolves against real timings when the chunk is
        // already retained, and waits as `pendingSeekWord` when it isn't —
        // targeting the chunk's start instead would silently lose up to a
        // whole chunk of the position the user actually asked for.
        var offset = offset
        if let wordIndex, let retained = retainedChunks[index],
           retained.wordTimings.indices.contains(wordIndex) {
            offset = retained.wordTimings[wordIndex].start
        }
        // Seeded immediately rather than waiting for the 1Hz ticker —
        // otherwise the scrubber visibly snaps back to where it was for up
        // to a second after the user lets go. It is also what the clock
        // reports until the node starts rendering the rescheduled buffer.
        lastResolvedPosition = (index, offset)
        currentChunkIndex = index
        elapsed = (startTime(forChunk: index) ?? 0) + offset
        refreshBookProgress()
        if let retained = retainedChunks[index] {
            bufferingForIndex = nil
            pendingSeekOffset = nil
            pendingSeekWord = nil
            scheduleCursorFrameOffset = frameOffset(forChunk: retained, at: offset)
            scheduleReady()
        } else {
            isBuffering = true
            bufferingForIndex = index
            pendingSeekOffset = wordIndex == nil ? offset : nil
            pendingSeekWord = wordIndex
        }
        updateNowPlaying()
    }

    /// Stops and clears the node's queue without tearing down the engine —
    /// what a seek needs (the queue is strictly ordered, so the only way to
    /// play something out of turn is to flush and reschedule from there).
    /// Bumps `playbackEpoch` so the discarded buffers' completion handlers,
    /// which `stop()` itself triggers, are ignored rather than mistaken for
    /// real playback progress.
    private func flushNode() {
        playbackEpoch += 1
        pendingBuffers = 0
        // `node.stop()` resets the node's own sample clock to zero, so the
        // span map it is read against has to reset in the same breath.
        scheduledSpans = []
        scheduledFrames = 0
        guard isConnected else { return }
        node.stop()
        isNodeRunning = false
    }

    // MARK: - Page lifecycle

    private func beginPage(
        ref: ReaderPageRef, page: ReaderPage, startingAtChunk: Int = 0, wordIndex: Int? = nil
    ) {
        // Any buffer still outstanding belongs to the page being left.
        playbackEpoch += 1
        activeRef = ref
        pageIndex = ref.pageIndex
        chunkTexts = KokoroTextChunker.chunk(page.text)
        pageTotalCharacters = chunkTexts.reduce(0) { $0 + $1.count }
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        retainedChunks = [:]
        playingChunk = 0
        scheduleCursor = 0
        scheduleCursorFrameOffset = 0
        bufferingForIndex = nil
        pendingSeekOffset = nil
        upcomingPages = []
        hasReachedEndOfBook = false
        duration = 0
        lastResolvedPosition = (0, 0)
        currentChunkIndex = 0
        refreshBookProgress()
        positionWriter?(ref.pageIndex)
        statsTracker.beginListening(
            ref: ref, bookTitle: bookTitle, voice: voice, engine: .kokoroAne)
        guard !chunkTexts.isEmpty else { return }
        let clamped = chunkTexts.indices.contains(startingAtChunk) ? startingAtChunk : 0
        playingChunk = clamped
        scheduleCursor = clamped
        currentChunkIndex = clamped
        lastResolvedPosition = (clamped, 0)
        isBuffering = true
        bufferingForIndex = clamped
        pendingSeekWord = wordIndex
    }

    /// The node's completion callback for the chunk at `index`. Guarded on
    /// `epoch` first: `AVAudioPlayerNode.stop()` fires handlers for the
    /// buffers it discards, so a seek's flush produces callbacks that are
    /// otherwise indistinguishable from real completions — and an index
    /// comparison alone can't tell them apart when the seek stayed inside
    /// the same chunk, which is exactly when a stale callback would
    /// spuriously advance the page (and, on the last chunk, record it
    /// complete and jump to the next one).
    private func finishedChunk(_ index: Int, epoch: Int) {
        guard epoch == playbackEpoch else { return }
        pendingBuffers -= 1
        guard playingChunk == index else { return }
        let nextIndex = index + 1
        if nextIndex < chunkTexts.count {
            playingChunk = nextIndex
            // Published here rather than waiting for the 1Hz ticker: this
            // *is* the boundary, and the read-along's chunk highlight would
            // otherwise sit on the previous paragraph for up to a second.
            currentChunkIndex = nextIndex
            if pendingBuffers <= 0 {
                log("STARVED at chunk \(nextIndex + 1) — synthesis fell behind")
                scheduleSilence()
            }
            updateNowPlaying()
            return
        }
        // End of this page's chunks.
        guard let ref = activeRef else { return }
        statsTracker.endListening(pageCompleted: true)
        guard continuesToNextPage else {
            isPlaying = false
            isBuffering = false
            updateNowPlaying()
            return
        }
        if upcomingPages.isEmpty {
            guard let page = pageProvider?(ref.pageIndex + 1) else {
                isPlaying = false
                isBuffering = false
                isFinishedBook = true
                updateNowPlaying()
                return
            }
            let newRef = ReaderPageRef(projectID: ref.projectID, pageIndex: ref.pageIndex + 1)
            upcomingPages = [
                UpcomingPage(ref: newRef, chunkTexts: KokoroTextChunker.chunk(page.text))
            ]
        }
        promoteNextPage()
    }

    /// Swaps the prefetched next page in and keeps the node running —
    /// deliberately not routed through `stop()`, which would tear down the
    /// session this is continuing. Calls `scheduleReady()` once state is
    /// reset to the new page so its opening chunks (normally already
    /// retained by then) go straight onto the node with nothing for it to
    /// fall silent over in between.
    private func promoteNextPage() {
        while let candidate = upcomingPages.first, candidate.chunkTexts.isEmpty {
            upcomingPages.removeFirst()
        }
        guard !upcomingPages.isEmpty else {
            isPlaying = false
            isBuffering = false
            isFinishedBook = true
            updateNowPlaying()
            return
        }
        let promoted = upcomingPages.removeFirst()
        // Silence buffers queued while the old page starved would otherwise
        // keep rescheduling themselves against the new page's accounting.
        playbackEpoch += 1
        pendingBuffers = 0
        hasReachedEndOfBook = false
        activeRef = promoted.ref
        pageIndex = promoted.ref.pageIndex
        chunkTexts = promoted.chunkTexts
        retainedChunks = promoted.retained
        playingChunk = 0
        scheduleCursor = 0
        scheduleCursorFrameOffset = 0
        bufferingForIndex = nil
        pendingSeekOffset = nil
        pageTotalCharacters = promoted.chunkTexts.reduce(0) { $0 + $1.count }
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        for (index, retained) in promoted.retained where promoted.chunkTexts.indices.contains(index) {
            synthesizedDurationSoFar += retained.duration
            synthesizedCharsSoFar += promoted.chunkTexts[index].count
        }
        refreshDurationEstimate()
        lastResolvedPosition = (0, 0)
        currentChunkIndex = 0
        refreshBookProgress()
        positionWriter?(promoted.ref.pageIndex)
        statsTracker.beginListening(
            ref: promoted.ref, bookTitle: bookTitle, voice: voice, engine: .kokoroAne)
        log("advanced to page \(promoted.ref.pageIndex + 1) of \(pageCount)")
        if retainedChunks[0] == nil {
            // Rare — a short enough page that the lookahead didn't cross it
            // in time. The pump will pick chunk 0 up as its next target
            // (it always scans from `playingChunk`, which is 0 again now).
            isBuffering = true
            bufferingForIndex = 0
        }
        scheduleReady()
        updateNowPlaying()
    }

    // MARK: - Synthesis pump

    private enum SynthesisTarget {
        case current(Int)
        case upcoming(pageOffset: Int, chunkIndex: Int)
    }

    /// Self-healing scan from `playingChunk`, exactly
    /// the deleted `ChapterAudioPlayer.nextSynthesisTarget()`'s shape — retains
    /// everything within the lookahead window rather than evicting (a page
    /// is small enough that eviction buys nothing here), and spills across
    /// the page boundary once the window runs past the last chunk.
    private func nextSynthesisTarget() -> SynthesisTarget? {
        guard activeRef != nil else { return nil }
        let upper = playingChunk + Self.maxSynthesisLookahead
        for index in playingChunk...upper where chunkTexts.indices.contains(index) {
            if retainedChunks[index] == nil { return .current(index) }
        }
        guard continuesToNextPage, upper >= chunkTexts.count - 1 else { return nil }
        var remaining = upper - (chunkTexts.count - 1)
        guard remaining > 0, !hasReachedEndOfBook else { return nil }

        var pageOffset = 0
        while true {
            if pageOffset >= upcomingPages.count {
                guard let ref = activeRef else { return nil }
                let candidatePageIndex = ref.pageIndex + 1 + upcomingPages.count
                guard let page = pageProvider?(candidatePageIndex) else {
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
            let (samples, sampleRate, chunkDuration, wordTimings) =
                try await synthesis.synthesizeChunkSamples(chunkText: text, voice: voice)
            guard activeRef != nil, chunkTexts.indices.contains(index), chunkTexts[index] == text
            else { return }
            retainedChunks[index] = RetainedChunk(
                samples: samples, sampleRate: sampleRate, duration: chunkDuration,
                wordTimings: wordTimings)
            synthesizedDurationSoFar += chunkDuration
            synthesizedCharsSoFar += text.count
            refreshDurationEstimate()
            // Tells the read-along this chunk's paragraph can upgrade from
            // its plain-text fallback to real word timings.
            synthesisRevision += 1
            if bufferingForIndex == index {
                bufferingForIndex = nil
                isBuffering = false
                // Apply the offset the seek that's been waiting on this
                // chunk asked for. Without this a seek into an
                // unsynthesized chunk silently restarted it from its
                // beginning — losing up to a whole chunk (~25s) of the
                // position the user actually dragged to.
                if let retained = retainedChunks[index], index == playingChunk {
                    let target =
                        pendingSeekWord.flatMap {
                            retained.wordTimings.indices.contains($0)
                                ? retained.wordTimings[$0].start : nil
                        } ?? pendingSeekOffset
                    if let target {
                        scheduleCursorFrameOffset = frameOffset(forChunk: retained, at: target)
                        lastResolvedPosition = (index, target)
                    }
                }
                pendingSeekOffset = nil
                pendingSeekWord = nil
            }
            scheduleReady()
        case .upcoming(let pageOffset, let chunkIndex):
            guard upcomingPages.indices.contains(pageOffset),
                upcomingPages[pageOffset].chunkTexts.indices.contains(chunkIndex)
            else { return }
            let text = upcomingPages[pageOffset].chunkTexts[chunkIndex]
            let (samples, sampleRate, chunkDuration, wordTimings) =
                try await synthesis.synthesizeChunkSamples(chunkText: text, voice: voice)
            guard upcomingPages.indices.contains(pageOffset),
                upcomingPages[pageOffset].chunkTexts.indices.contains(chunkIndex),
                upcomingPages[pageOffset].chunkTexts[chunkIndex] == text
            else { return }
            upcomingPages[pageOffset].retained[chunkIndex] = RetainedChunk(
                samples: samples, sampleRate: sampleRate, duration: chunkDuration,
                wordTimings: wordTimings)
            // Deliberately no `synthesisRevision` bump: this chunk belongs
            // to a page that isn't displayed, and the revision exists to
            // tell the *current* page's paragraphs to pick up timings.
        }
    }

    private func startPump() {
        pump?.cancel()
        pump = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let target = self.nextSynthesisTarget() else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                do {
                    try await self.synthesizeAndRetain(target)
                } catch {
                    self.log("SYNTHESIS FAILED: \(error)")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    // MARK: - Scheduling onto the node

    /// Schedules every already-retained chunk of the *current* page starting
    /// at `scheduleCursor`, stopping the moment it hits one that isn't
    /// retained yet — `synthesizeAndRetain` calls this again once that
    /// chunk lands. Deliberately does not reach into `upcomingPages`: a
    /// buffer's completion closure captures a plain chunk index, which
    /// would go stale the instant `promoteNextPage()` reassigns `chunkTexts`
    /// out from under it. Instead `promoteNextPage()` itself calls this
    /// again right after resetting state to the new page — by then the new
    /// page's opening chunks are normally already *retained* (the synthesis
    /// pump crosses the page boundary well before playback reaches it), so
    /// scheduling them happens synchronously in the same run-loop turn the
    /// old page's last chunk finishes in, with nothing for the node to fall
    /// silent over in between.
    private func scheduleReady() {
        while chunkTexts.indices.contains(scheduleCursor) {
            guard let retained = retainedChunks[scheduleCursor] else { return }
            let startFrame = scheduleCursor == playingChunk ? scheduleCursorFrameOffset : 0
            scheduleCursorFrameOffset = 0
            guard let buffer = Self.makeBuffer(from: retained, startFrame: startFrame) else { return }
            // Where this buffer begins inside its own chunk — zero except
            // for the sliced first buffer after a mid-chunk seek. The clock
            // adds it back so word timings, which are measured from the
            // chunk's true start, still line up.
            let chunkOffset =
                retained.sampleRate > 0 ? Double(startFrame) / Double(retained.sampleRate) : 0
            schedule(buffer, at: scheduleCursor, chunkOffset: chunkOffset)
            scheduleCursor += 1
        }
    }

    private func schedule(
        _ buffer: AVAudioPCMBuffer, at index: Int, chunkOffset: TimeInterval
    ) {
        if !isConnected {
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            format = buffer.format
            engine.prepare()
            do {
                try engine.start()
            } catch {
                log("engine start failed: \(error.localizedDescription)")
                return
            }
            isConnected = true
        }
        pendingBuffers += 1
        let epoch = playbackEpoch
        scheduledSpans.append(
            ScheduledSpan(
                startSample: scheduledFrames,
                frameCount: AVAudioFramePosition(buffer.frameLength),
                chunkIndex: index, isSilence: false,
                chunkOffset: chunkOffset))
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishedChunk(index, epoch: epoch) }
        }
        // Auto-start on the first buffer of a session, and restart after a
        // seek's flush — but never resume against an explicit pause.
        guard !isUserPaused else { return }
        let wasRunning = isNodeRunning
        startNodeIfNeeded()
        if !isPlaying || !wasRunning {
            isPlaying = true
            if !wasRunning { log("playback started") }
            updateNowPlaying()
        }
    }

    private func scheduleSilence() {
        guard !isFinishedBook, let format,
              let silence = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 2))
        else { return }
        silence.frameLength = silence.frameCapacity
        pendingBuffers += 1
        scheduledSpans.append(
            ScheduledSpan(
                startSample: scheduledFrames,
                frameCount: AVAudioFramePosition(silence.frameLength),
                chunkIndex: playingChunk, isSilence: true, chunkOffset: 0))
        scheduledFrames += AVAudioFramePosition(silence.frameLength)
        let epoch = playbackEpoch
        node.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, epoch == self.playbackEpoch else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers <= 0 { self.scheduleSilence() }
            }
        }
    }

    // MARK: - Buffers

    private static func makeBuffer(from chunk: RetainedChunk, startFrame: Int) -> AVAudioPCMBuffer? {
        guard startFrame < chunk.samples.count,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Double(chunk.sampleRate),
                channels: 1, interleaved: false)
        else { return nil }
        let frameCount = chunk.samples.count - startFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        chunk.samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channelData[0].update(from: base + startFrame, count: frameCount)
        }
        return buffer
    }

    private func frameOffset(forChunk chunk: RetainedChunk, at time: TimeInterval) -> Int {
        guard chunk.duration > 0, !chunk.samples.isEmpty else { return 0 }
        let fraction = max(0, min(time / chunk.duration, 1))
        // Capped one frame short of the end: at exactly `samples.count`,
        // `makeBuffer` has nothing left to copy and returns nil, which
        // schedules nothing at all — dragging the scrubber to its far right
        // stalled silently instead of landing at the end of the page.
        return min(Int(fraction * Double(chunk.samples.count)), chunk.samples.count - 1)
    }

    // MARK: - Time & progress

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isScrubbing else { return }
                let position = self.resolvedPosition()
                if position.chunkIndex != self.currentChunkIndex {
                    self.currentChunkIndex = position.chunkIndex
                }
                self.elapsed = self.elapsedNow()
                self.refreshBookProgress()
                self.updateNowPlaying()
            }
        }
    }

    // MARK: - The render clock

    /// Where playback actually is, as `(chunk, offset within that chunk)`,
    /// read from the node's own render clock against `scheduledSpans`.
    ///
    /// Chunk-relative on purpose: `WordTiming.start` is chunk-relative, so
    /// this is the shape word highlighting needs. Silence spans report the
    /// preceding speech span's end, so a starvation stretch *holds* the
    /// highlight on the last spoken word instead of sliding past it.
    /// `lastRenderTime` returns nil whenever the node isn't rendering, so
    /// the last good answer is cached and returned while paused.
    private func resolvedPosition() -> (chunkIndex: Int, offset: TimeInterval) {
        guard isConnected, let renderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: renderTime),
              playerTime.sampleRate > 0
        else { return lastResolvedPosition }

        let sample = playerTime.sampleTime
        // Spans fully behind the playhead can never be resolved against
        // again, and this runs at the highlight's ~12Hz poll: a starvation
        // stretch appends two silence spans a second, so without pruning
        // the scan below grows for as long as the page plays.
        if scheduledSpans.count > 64,
           let lastConsumed = scheduledSpans.lastIndex(where: {
               $0.startSample + $0.frameCount <= sample
           }), lastConsumed > 0 {
            scheduledSpans.removeFirst(lastConsumed)
        }
        guard let span = scheduledSpans.last(where: { $0.startSample <= sample }) else {
            return lastResolvedPosition
        }
        if span.isSilence {
            // Hold at the end of the last real speech span rather than
            // counting silence as spoken time.
            return lastResolvedPosition
        }
        let into = Double(sample - span.startSample) / playerTime.sampleRate
        let resolved = (span.chunkIndex, span.chunkOffset + max(0, into))
        lastResolvedPosition = resolved
        return resolved
    }

    /// This chunk's word timings — empty when none exist (non-English
    /// voice, or a chunk not yet synthesized), which falls back to
    /// highlighting the whole chunk.
    func wordTimings(forChunk index: Int) -> [WordTiming] {
        retainedChunks[index]?.wordTimings ?? []
    }

    /// The word to highlight right now. Takes no time argument on purpose:
    /// it resolves the chunk *and* the offset from a single clock read, so
    /// a chunk boundary can never match the new chunk's offset against the
    /// old chunk's timings — which it would if the caller passed
    /// a raw position while `currentChunkIndex` was still a publish behind.
    func currentWordIndex() -> Int? {
        let position = resolvedPosition()
        let timings = wordTimings(forChunk: position.chunkIndex)
        guard !timings.isEmpty else { return nil }
        var index = 0
        for (i, timing) in timings.enumerated() where timing.start <= position.offset {
            index = i
        }
        return index
    }

    /// Page-relative elapsed, for the scrubber and Now Playing — the
    /// sounding chunk's own start plus how far into it playback is.
    private func elapsedNow() -> TimeInterval {
        let position = resolvedPosition()
        return (startTime(forChunk: position.chunkIndex) ?? 0) + position.offset
    }

    private func refreshBookProgress() {
        guard pageCount > 0 else {
            bookProgress = 0
            return
        }
        let pageFraction = duration > 0 ? min(max(elapsedNow() / duration, 0), 1) : 0
        bookProgress = (Double(pageIndex) + pageFraction) / Double(pageCount)
    }

    private func startTime(forChunk index: Int) -> TimeInterval? {
        guard chunkTexts.indices.contains(index) else { return nil }
        guard index > 0 else { return 0 }
        return (0..<index).reduce(0) { $0 + estimatedDuration(forChunkAt: $1) }
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

    // MARK: - Session, lock screen, system events

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        } catch {
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)

        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]

        center.playCommand.addTarget { [weak self] _ in
            guard let self, !self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.isPlaying else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.togglePlayPause()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipForward()
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            self.skipBackward()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self, let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self.seek(to: event.positionTime)
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, let ref = self.activeRef, ref.pageIndex + 1 < self.pageCount
            else { return .commandFailed }
            self.jumpToPage(ref.pageIndex + 1)
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, let ref = self.activeRef, ref.pageIndex > 0 else { return .commandFailed }
            self.jumpToPage(ref.pageIndex - 1)
            return .success
        }
    }

    /// Next/previous-page, reached from the lock screen's track buttons or
    /// the now-playing view's own ⏮/⏭. Not the same path as continuous
    /// auto-advance (`promoteNextPage`): this is a deliberate user jump, so
    /// it re-fetches the target page directly rather than relying on
    /// whatever's already prefetched.
    func jumpToPage(_ index: Int) {
        guard let projectID, let page = pageProvider?(index) else { return }
        flushNode()
        beginPage(ref: ReaderPageRef(projectID: projectID, pageIndex: index), page: page)
        updateNowPlaying()
    }

    /// Known ways background audio dies quietly — without these an
    /// interruption or a route change leaves the node stopped with no
    /// indication why. Ported from `StreamingPlaybackLab`, plus route-change
    /// handling and honouring `.shouldResume` (both gaps the lab left open,
    /// acceptable in a scratch harness, not here).
    private func observeSystemEvents() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleRouteChange(note) }
        })
        observers.append(center.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        })
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }
        switch type {
        case .began:
            log("interruption began")
            pauseEngine()
            isPlaying = false
        case .ended:
            let shouldResume =
                (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map {
                    AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
                } ?? false
            // Not resuming leaves this in the same state an explicit pause
            // does, so a later tap on play is what restarts it.
            guard shouldResume else {
                log("interruption ended — not resuming")
                isUserPaused = true
                updateNowPlaying()
                return
            }
            log("interruption ended — resuming")
            try? AVAudioSession.sharedInstance().setActive(true)
            startNodeIfNeeded()
            isPlaying = true
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    /// A device disappearing (headphones unplugged, AirPods disconnected)
    /// must pause rather than let it fall back to the speaker unasked.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable, isPlaying
        else { return }
        log("route changed — output device unavailable, pausing")
        if isNodeRunning { pauseEngine() }
        // Latched, so the next chunk landing doesn't quietly resume audio
        // through the speaker the user just unplugged from.
        isUserPaused = true
        isPlaying = false
        updateNowPlaying()
    }

    private func handleConfigurationChange() {
        log("engine configuration changed")
        // Only resume an engine that *should* be running: it is now also
        // stopped deliberately while paused, and restarting it here would
        // put the session back to "playing" behind the user's back.
        guard isConnected, isPlaying, !engine.isRunning else { return }
        isNodeRunning = false
        startNodeIfNeeded()
        log("engine restarted")
    }

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = activeRef.map { "Page \($0.pageIndex + 1) of \(pageCount)" }
        info[MPMediaItemPropertyAlbumTitle] = bookTitle
        info[MPMediaItemPropertyArtist] = VoiceDisplayName.forCode(voice)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedNow()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // Posted alongside the rate so the lock screen knows this is a
        // 1.0x-when-playing source and extrapolates the elapsed time
        // correctly between our 1Hz updates.
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        // Deliberately no `center.playbackState`: its own header says it
        // "only applies on macOS, where playback state cannot be determined
        // by the application's audio session". On iOS it is a no-op, and
        // the session *is* the state — which is why pausing stops the
        // engine rather than only the node (see `startNodeIfNeeded`).
    }

    private static func loadArtwork(url: URL?) -> MPMediaItemArtwork? {
        guard let url, let image = UIImage(contentsOfFile: url.path) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func log(_ message: String) {
        let stamp = String(format: "%6.1fs", Date().timeIntervalSince(startedAt))
        events.append("\(stamp)  \(message)")
        if events.count > 120 { events.removeFirst(events.count - 120) }
    }
}
