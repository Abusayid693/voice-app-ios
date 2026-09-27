import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// Music-style, continuous, lock-screen-surviving playback of a whole book —
/// a second, independent playback owner alongside `ChapterAudioPlayer`
/// (`Features/Chapters/`), not a replacement for it. Deliberately separate:
/// see `docs/adr/0012-two-playback-engines.md` for why one player couldn't
/// serve both read-along and this.
///
/// The engine is `StreamingPlaybackLab` (`Features/Chapters/Services/
/// StreamingPlaybackLab.swift`) promoted to a real feature: one
/// `AVAudioPlayerNode` with buffers scheduled onto it, gapless, plus a
/// silence keep-alive so a slow synthesis stretch can't leave the node
/// silent long enough for iOS to suspend the app (once suspended, synthesis
/// stops too, and it never recovers). The page model — bounded lookahead,
/// cross-page prefetch, position/stats — is ported from `ChapterAudioPlayer`,
/// deliberately simplified: no word timings, no play-from-word, because
/// nothing here renders words.
///
/// **Scheduling vs. synthesis are two separate cursors.** A node's queue is
/// strictly ordered — buffers can't be reordered or inserted once scheduled —
/// so unlike `ChapterAudioPlayer` (one `AVAudioPlayer` per chunk, played on
/// demand whenever it's ready) this retains a *whole page's* chunks (small —
/// a page is ≤2,000 words, a handful of ~350-char chunks) rather than
/// evicting, and keeps `scheduleCursor` (what's been handed to the node, in
/// order) separate from the self-healing synthesis scan (what's been
/// *retained*, which may land out of order within the lookahead window).
/// Seeking flushes the node's queue (`node.stop()`) and restarts
/// `scheduleCursor` from the target — a chunk already retained schedules
/// immediately (sliced to the right frame offset for an intra-chunk seek);
/// one that isn't triggers synthesis first, same `bufferingForIndex`/
/// `pendingSeekOffset` shape `ChapterAudioPlayer` uses for the same problem.
///
/// **Elapsed time is wall-clock, not a queried playback position** — there
/// is no per-node equivalent of `AVAudioPlayer.currentTime`. Because
/// scheduling is gapless, wall-clock time since a page's audio started
/// sounding (minus paused time) *is* exactly the elapsed position, the same
/// technique `StreamingPlaybackLab.elapsedNow()` uses — just page-scoped and
/// reset on every seek rather than book-scoped.
@MainActor
final class BookAudioPlayer: ObservableObject {
    /// Same bound as `ChapterAudioPlayer.maxSynthesisLookahead` and the lab's
    /// own — keeps the ANE idling between chunks rather than running flat
    /// out, and caps how long a seek can wait behind synthesis already in
    /// flight.
    static let maxSynthesisLookahead = 2

    @Published private(set) var activeRef: ReaderPageRef?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// Elapsed within the *current page* — wall-clock while sounding, reset
    /// on every seek. What the draggable page scrubber binds to.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Estimated length of the current page, refined as real chunks land —
    /// see `ChapterAudioPlayer`'s own doc comment for why this is an
    /// estimate, not a running sum: bounded lookahead means a sum of
    /// retained audio would freeze at ~2 chunks' worth.
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

    /// Called just before this player starts or resumes audio — wired in
    /// `KokoroAneTestApp` to `ChapterAudioPlayer.pauseIfPlaying()`, the other
    /// half of the mutual-exclusion rule `willStartPlaying` on that class
    /// documents.
    var willStartPlaying: (() -> Void)?

    private let synthesis: ChapterSynthesisService
    private let statsTracker: ReadingStatsTracker

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var isConnected = false
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
    /// in the first — the same "arriving chunk resumed audio on its own"
    /// bug this app already fixed once in `ChapterAudioPlayer`.
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

    private var chunkTexts: [String] = []
    private struct RetainedChunk {
        let samples: [Float]
        let sampleRate: Int
        let duration: TimeInterval
    }
    private var retainedChunks: [Int: RetainedChunk] = [:]
    /// Index into `chunkTexts` of the chunk currently sounding — advanced by
    /// the node's completion callback, and what the self-healing synthesis
    /// scan reads from (mirrors `ChapterAudioPlayer.currentChunkIndex`).
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

    // Wall-clock elapsed tracking — see the type's own doc comment.
    private var pageAccumulated: TimeInterval = 0
    private var playingSince: Date?
    private var isScrubbing = false

    private var artwork: MPMediaItemArtwork?

    init(synthesis: ChapterSynthesisService, statsTracker: ReadingStatsTracker) {
        self.synthesis = synthesis
        self.statsTracker = statsTracker
    }

    func isActive(_ ref: ReaderPageRef) -> Bool { activeRef == ref }

    // MARK: - Control

    /// Starts (or restarts) continuous playback of a book from `startIndex`
    /// — always `project.lastReadPageIndex` at the call site, same source
    /// `ChapterPlayerView.init` reads, so opening either surface after the
    /// other resumes where it left off.
    func start(
        project: SavedGeneration, page: ReaderPage, startIndex: Int,
        pageProvider: @escaping (Int) -> ReaderPage?,
        positionWriter: @escaping (Int) -> Void
    ) {
        willStartPlaying?()
        stop()

        projectID = project.id
        voice = project.voiceName
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
        engine.attach(node)
        startedAt = Date()
        isFinishedBook = false

        beginPage(ref: ReaderPageRef(projectID: project.id, pageIndex: startIndex), page: page)
        log("start: \(bookTitle), page \(startIndex + 1) of \(pageCount)")
        startPump()
        startTicker()
    }

    /// Works before the first chunk has landed too — pausing while the
    /// opening chunk is still synthesizing latches `isUserPaused` so that
    /// chunk schedules without starting playback, rather than the button
    /// sitting dead for the first few seconds of a session.
    func togglePlayPause() {
        guard activeRef != nil else { return }
        if isPlaying || (!isUserPaused && !isConnected) {
            if isNodeRunning {
                node.pause()
                isNodeRunning = false
            }
            pageAccumulated = elapsedNow()
            playingSince = nil
            isUserPaused = true
            isPlaying = false
            statsTracker.pauseListening()
        } else {
            willStartPlaying?()
            isUserPaused = false
            // Nothing scheduled yet (paused through the initial buffer, or
            // resumed after a seek that's still waiting on synthesis) —
            // `schedule()` starts the node as soon as a buffer lands.
            if isConnected, pendingBuffers > 0 {
                startNodeIfNeeded()
                playingSince = Date()
                isPlaying = true
            }
            statsTracker.resumeListening()
        }
        updateNowPlaying()
    }

    private func startNodeIfNeeded() {
        guard isConnected, !isNodeRunning else { return }
        node.play()
        isNodeRunning = true
    }

    /// Pauses without stopping — the yield half of the mutual-exclusion rule
    /// (`ChapterAudioPlayer.pauseIfPlaying` is the other half).
    func pauseIfPlaying() {
        guard isPlaying else { return }
        togglePlayPause()
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
            engine.detach(node)
            isConnected = false
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
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
        upcomingPages = []
        hasReachedEndOfBook = false
        pageTotalCharacters = 0
        synthesizedDurationSoFar = 0
        synthesizedCharsSoFar = 0
        pageAccumulated = 0
        playingSince = nil
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

    private func seekToChunk(_ index: Int, offset: TimeInterval) {
        guard chunkTexts.indices.contains(index) else { return }
        flushNode()
        playingChunk = index
        scheduleCursor = index
        pageAccumulated = (startTime(forChunk: index) ?? 0) + offset
        // Published immediately rather than waiting for the 1Hz ticker —
        // otherwise the scrubber visibly snaps back to where it was for up
        // to a second after the user lets go.
        elapsed = pageAccumulated
        refreshBookProgress()
        if let retained = retainedChunks[index] {
            bufferingForIndex = nil
            pendingSeekOffset = nil
            scheduleCursorFrameOffset = frameOffset(forChunk: retained, at: offset)
            playingSince = isPlaying ? Date() : nil
            scheduleReady()
        } else {
            isBuffering = true
            bufferingForIndex = index
            pendingSeekOffset = offset
            playingSince = nil
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
        guard isConnected else { return }
        node.stop()
        isNodeRunning = false
    }

    // MARK: - Page lifecycle

    private func beginPage(ref: ReaderPageRef, page: ReaderPage) {
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
        pageAccumulated = 0
        playingSince = isPlaying ? Date() : nil
        refreshBookProgress()
        positionWriter?(ref.pageIndex)
        statsTracker.beginListening(
            ref: ref, bookTitle: bookTitle, voice: voice, engine: .kokoroAne)
        guard !chunkTexts.isEmpty else { return }
        isBuffering = true
        bufferingForIndex = 0
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
        pageAccumulated = 0
        playingSince = isPlaying ? Date() : nil
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
    /// `ChapterAudioPlayer.nextSynthesisTarget()`'s shape — retains
    /// everything within the lookahead window rather than evicting (a page
    /// is small enough that eviction buys nothing here), and spills across
    /// the page boundary once the window runs past the last chunk.
    private func nextSynthesisTarget() -> SynthesisTarget? {
        guard activeRef != nil else { return nil }
        let upper = playingChunk + Self.maxSynthesisLookahead
        for index in playingChunk...upper where chunkTexts.indices.contains(index) {
            if retainedChunks[index] == nil { return .current(index) }
        }
        guard upper >= chunkTexts.count - 1 else { return nil }
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
            let (samples, sampleRate, chunkDuration) =
                try await synthesis.synthesizeChunkSamples(chunkText: text, voice: voice)
            guard activeRef != nil, chunkTexts.indices.contains(index), chunkTexts[index] == text
            else { return }
            retainedChunks[index] = RetainedChunk(
                samples: samples, sampleRate: sampleRate, duration: chunkDuration)
            synthesizedDurationSoFar += chunkDuration
            synthesizedCharsSoFar += text.count
            refreshDurationEstimate()
            if bufferingForIndex == index {
                bufferingForIndex = nil
                isBuffering = false
                // Apply the offset the seek that's been waiting on this
                // chunk asked for. Without this a seek into an
                // unsynthesized chunk silently restarted it from its
                // beginning — losing up to a whole chunk (~25s) of the
                // position the user actually dragged to.
                if let pendingSeekOffset, let retained = retainedChunks[index], index == playingChunk {
                    scheduleCursorFrameOffset = frameOffset(forChunk: retained, at: pendingSeekOffset)
                }
                pendingSeekOffset = nil
            }
            scheduleReady()
        case .upcoming(let pageOffset, let chunkIndex):
            guard upcomingPages.indices.contains(pageOffset),
                upcomingPages[pageOffset].chunkTexts.indices.contains(chunkIndex)
            else { return }
            let text = upcomingPages[pageOffset].chunkTexts[chunkIndex]
            let (samples, sampleRate, chunkDuration) =
                try await synthesis.synthesizeChunkSamples(chunkText: text, voice: voice)
            guard upcomingPages.indices.contains(pageOffset),
                upcomingPages[pageOffset].chunkTexts.indices.contains(chunkIndex),
                upcomingPages[pageOffset].chunkTexts[chunkIndex] == text
            else { return }
            upcomingPages[pageOffset].retained[chunkIndex] = RetainedChunk(
                samples: samples, sampleRate: sampleRate, duration: chunkDuration)
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
            schedule(buffer, at: scheduleCursor)
            scheduleCursor += 1
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, at index: Int) {
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
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishedChunk(index, epoch: epoch) }
        }
        // Auto-start on the first buffer of a session, and restart after a
        // seek's flush — but never resume against an explicit pause.
        guard !isUserPaused else { return }
        let wasRunning = isNodeRunning
        startNodeIfNeeded()
        // Re-anchors the wall clock whenever audio resumes from a state that
        // had none running. `isPlaying` alone can't gate this: a seek or a
        // page jump *while playing* leaves it true with `playingSince` nil,
        // which would freeze `elapsed` for the rest of the page.
        if playingSince == nil { playingSince = Date() }
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
                self.elapsed = self.elapsedNow()
                self.refreshBookProgress()
                self.updateNowPlaying()
            }
        }
    }

    private func elapsedNow() -> TimeInterval {
        pageAccumulated + (playingSince.map { Date().timeIntervalSince($0) } ?? 0)
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
            pageAccumulated = elapsedNow()
            playingSince = nil
            isNodeRunning = false
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
            if !engine.isRunning { try? engine.start() }
            startNodeIfNeeded()
            playingSince = Date()
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
        if isNodeRunning {
            node.pause()
            isNodeRunning = false
        }
        pageAccumulated = elapsedNow()
        playingSince = nil
        // Latched, so the next chunk landing doesn't quietly resume audio
        // through the speaker the user just unplugged from.
        isUserPaused = true
        isPlaying = false
        updateNowPlaying()
    }

    private func handleConfigurationChange() {
        log("engine configuration changed")
        guard isConnected, !engine.isRunning else { return }
        do {
            try engine.start()
            if isPlaying {
                isNodeRunning = false
                startNodeIfNeeded()
            }
            log("engine restarted")
        } catch {
            log("engine restart failed: \(error.localizedDescription)")
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = activeRef.map { "Page \($0.pageIndex + 1) of \(pageCount)" }
        info[MPMediaItemPropertyAlbumTitle] = bookTitle
        info[MPMediaItemPropertyArtist] = VoiceDisplayName.forCode(voice)
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedNow()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
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
