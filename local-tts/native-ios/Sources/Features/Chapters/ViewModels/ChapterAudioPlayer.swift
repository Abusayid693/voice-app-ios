import AVFoundation
import Foundation

/// The single owner of every chapter `AVAudioPlayer` in the app — both the
/// saved path (one merged file, real duration/scrubbing) and the
/// streaming path (synthesize-and-play one chunk at a time, nothing
/// persisted). One object, one `player` field, so "play chapter 2 while
/// chapter 1 streams" is just `stop()` then start the new one — the same
/// shape `VoicePreviewPlayer.toggle` already proves correct. Kept off
/// `TTSViewModel` per this app's own re-render rule: the scrubber ticks
/// ~4x/sec, and `TTSViewModel`-observing views (the Trending carousel,
/// voice pickers) shouldn't re-render for that.
enum ChapterPlaybackMode: Equatable {
    case saved
    case streaming
}

@MainActor
final class ChapterAudioPlayer: ObservableObject {
    @Published private(set) var activeRef: ChapterRef?
    @Published private(set) var mode: ChapterPlaybackMode?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentChunkIndex = 0

    /// Read-along text for whichever mode is active — the saved
    /// manifest's chunk texts, or the streaming chunks as they're known.
    private(set) var chunkTexts: [String] = []

    private var player: AVAudioPlayer?
    private var delegate: AudioPlaybackDelegate?
    private var manifest: ChapterAudioManifest?
    private var streamTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var pendingChunkContinuation: CheckedContinuation<Void, Never>?
    private var isScrubbing = false

    private let synthesisService: ChapterSynthesisService

    init(synthesisService: ChapterSynthesisService) {
        self.synthesisService = synthesisService
    }

    func isActive(_ ref: ChapterRef) -> Bool { activeRef == ref }

    // MARK: - Saved playback (real duration, scrubbing)

    func playSaved(_ ref: ChapterRef, project: SavedGeneration) {
        stop()
        guard let audio = ChapterAudioStore.loadAudio(ref, project: project),
            let manifest = ChapterAudioStore.loadManifest(ref, project: project)
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
        } catch {
            resetState()
        }
    }

    private func handleSavedPlaybackFinished() {
        isPlaying = false
        elapsed = duration
        currentChunkIndex = max(0, chunkTexts.count - 1)
    }

    /// Where a given chunk starts in the merged file, for tap-a-paragraph-
    /// to-seek — nil during streaming (no manifest exists yet).
    func startTime(forChunk index: Int) -> TimeInterval? {
        guard let manifest, manifest.chunkStarts.indices.contains(index) else { return nil }
        return manifest.chunkStarts[index]
    }

    func seek(to time: TimeInterval) {
        guard mode == .saved, let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        elapsed = clamped
        if let manifest {
            currentChunkIndex = manifest.chunkIndex(atElapsed: clamped)
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

    // MARK: - Streaming playback (synthesize-and-play, nothing saved)

    func stream(_ ref: ChapterRef, chapter: Chapter, voice: String) {
        stop()
        activeRef = ref
        mode = .streaming
        chunkTexts = KokoroTextChunker.chunk(chapter.text)
        isBuffering = true

        let chunks = chunkTexts
        streamTask = Task { [weak self] in
            guard let self else { return }
            for (index, chunkText) in chunks.enumerated() {
                guard !Task.isCancelled, self.activeRef == ref else { return }
                do {
                    let data = try await self.synthesisService.synthesizeChunk(text: chunkText, voice: voice)
                    guard !Task.isCancelled, self.activeRef == ref else { return }
                    await self.playStreamedChunkAndWait(data, index: index)
                } catch {
                    break
                }
            }
            if self.activeRef == ref {
                self.isPlaying = false
                self.isBuffering = false
            }
        }
    }

    private func playStreamedChunkAndWait(_ data: Data, index: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingChunkContinuation = continuation
            do {
                let newPlayer = try AVAudioPlayer(data: data)
                let newDelegate = AudioPlaybackDelegate { [weak self] in
                    self?.resumePendingContinuation()
                }
                newPlayer.delegate = newDelegate
                player = newPlayer
                delegate = newDelegate
                currentChunkIndex = index
                isBuffering = false
                isPlaying = true
                newPlayer.play()
            } catch {
                resumePendingContinuation()
            }
        }
    }

    private func resumePendingContinuation() {
        pendingChunkContinuation?.resume()
        pendingChunkContinuation = nil
    }

    // MARK: - Shared transport

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
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
        resumePendingContinuation()
        resetState()
    }

    private func resetState() {
        activeRef = nil
        mode = nil
        isPlaying = false
        isBuffering = false
        elapsed = 0
        duration = 0
        currentChunkIndex = 0
        manifest = nil
        chunkTexts = []
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
        guard mode == .saved, let player, isPlaying, !isScrubbing else { return }
        elapsed = player.currentTime
        if let manifest {
            currentChunkIndex = manifest.chunkIndex(atElapsed: elapsed)
        }
    }
}
