import AVFoundation
import Foundation
import MediaPlayer
import UIKit

/// A self-contained experiment in continuous background playback: synthesise a
/// long text chunk by chunk and keep it playing with the screen locked.
///
/// Deliberately **not** built on `ChapterAudioPlayer`. That path creates one
/// `AVAudioPlayer` per chunk, so the audio genuinely stops at every boundary
/// while the next player is constructed. Reading along that gap is barely
/// noticeable; with the screen off it is the whole experience. It is also the
/// background risk: the `audio` background mode keeps an app alive only while
/// it is actually producing sound, so a long silence is what gets the app
/// suspended — and once suspended, synthesis stops too, so it cannot recover.
///
/// Scheduling PCM buffers onto a single `AVAudioPlayerNode` fixes both: playback
/// is gapless, and the node keeps rendering as long as anything is queued.
@MainActor
final class StreamingPlaybackLab: ObservableObject {
    /// How many chunks may be synthesised ahead of the one playing.
    ///
    /// Bounded on purpose. Synthesising the whole text up front would run the
    /// ANE flat out and heat the device for no benefit, and two chunks is
    /// already ~50 seconds of buffered audio — a wide cushion against the
    /// slower synthesis a backgrounded app gets.
    private let lookahead = 2

    @Published private(set) var isPlaying = false
    @Published private(set) var playingChunk = 0
    @Published private(set) var synthesisedChunks = 0
    @Published private(set) var totalChunks = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var estimatedDuration: TimeInterval = 0
    @Published private(set) var status = "Idle"
    /// Timestamped trace of everything that happened, shown in the harness.
    /// The whole point of the experiment is finding out *where* it dies, and
    /// nothing is observable while the screen is locked.
    @Published private(set) var events: [String] = []

    private let synthesis: ChapterSynthesisService
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()

    private var chunks: [String] = []
    private var voice = ""
    private var pump: Task<Void, Never>?
    private var ticker: Timer?
    private var isConnected = false
    private var observers: [NSObjectProtocol] = []
    private var startedAt = Date()

    /// Buffers scheduled on the node but not yet played out. When this reaches
    /// zero the node has nothing left to render and the audio goes silent —
    /// which is exactly what gets a backgrounded app suspended, so silence is
    /// scheduled to hold the slot instead.
    private var pendingBuffers = 0
    private var format: AVAudioFormat?
    private var isFinished = false

    // Elapsed is wall-clock while sound is coming out, which is exact precisely
    // because playback is gapless — there is no dead time to account for.
    private var accumulated: TimeInterval = 0
    private var playingSince: Date?

    // Feeds the duration estimate. The real total is unknowable until the last
    // chunk is synthesised, but chunks are uniform enough that a few real ones
    // extrapolate well — and a stable estimate beats a scrubber whose end keeps
    // moving.
    private var synthesisedDuration: TimeInterval = 0
    private var synthesisedCharacters = 0
    private var totalCharacters = 0

    init(synthesis: ChapterSynthesisService) {
        self.synthesis = synthesis
    }

    // MARK: - Control

    func start(text: String, voice: String) {
        stop()
        chunks = KokoroTextChunker.chunk(text)
        guard !chunks.isEmpty else {
            status = "Nothing to read"
            return
        }
        self.voice = voice
        totalChunks = chunks.count
        totalCharacters = chunks.reduce(0) { $0 + $1.count }

        do {
            try activateSession()
        } catch {
            status = "Audio session failed: \(error.localizedDescription)"
            return
        }
        configureRemoteCommands()
        observeSystemEvents()
        engine.attach(node)
        startedAt = Date()
        isFinished = false
        status = "Starting…"
        log("start: \(chunks.count) chunks, \(totalCharacters) chars")
        pump = Task { [weak self] in await self?.pumpChunks() }
        startTicker()
    }

    private func log(_ message: String) {
        let stamp = String(format: "%6.1fs", Date().timeIntervalSince(startedAt))
        events.append("\(stamp)  \(message)")
        if events.count > 120 { events.removeFirst(events.count - 120) }
    }

    /// Everything here is a known way for background audio to die quietly.
    /// Without the notifications an interruption or a route change leaves the
    /// engine stopped with no indication of why.
    private func observeSystemEvents() {
        removeObservers()
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.log("app backgrounded") }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.log("app foregrounded") }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(
            forName: Notification.Name.AVAudioEngineConfigurationChange, object: engine,
            queue: .main
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
            isPlaying = false
            accumulated = elapsedNow()
            playingSince = nil
        case .ended:
            log("interruption ended — resuming")
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { try? engine.start() }
            node.play()
            playingSince = Date()
            isPlaying = true
        @unknown default:
            break
        }
        updateNowPlaying()
    }

    private func handleConfigurationChange() {
        log("engine configuration changed")
        guard isConnected, !engine.isRunning else { return }
        do {
            try engine.start()
            node.play()
            log("engine restarted")
        } catch {
            log("engine restart failed: \(error.localizedDescription)")
        }
    }

    func togglePlayPause() {
        guard isConnected else { return }
        if isPlaying {
            node.pause()
            accumulated = elapsedNow()
            playingSince = nil
            isPlaying = false
        } else {
            node.play()
            playingSince = Date()
            isPlaying = true
        }
        updateNowPlaying()
    }

    func stop() {
        pump?.cancel()
        pump = nil
        removeObservers()
        pendingBuffers = 0
        format = nil
        isFinished = false
        ticker?.invalidate()
        ticker = nil
        if isConnected {
            node.stop()
            engine.stop()
            engine.detach(node)
            isConnected = false
        }
        isPlaying = false
        playingSince = nil
        accumulated = 0
        elapsed = 0
        playingChunk = 0
        synthesisedChunks = 0
        totalChunks = 0
        synthesisedDuration = 0
        synthesisedCharacters = 0
        totalCharacters = 0
        estimatedDuration = 0
        chunks = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        status = "Idle"
    }

    // MARK: - Synthesis pump

    private func pumpChunks() async {
        var index = 0
        while index < chunks.count, !Task.isCancelled {
            // The bounded-lookahead wait. Polling rather than signalling keeps
            // this readable, and a 200ms granularity is irrelevant against
            // chunks that are ~25 seconds long.
            while index > playingChunk + lookahead, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }

            status = "Synthesising \(index + 1)/\(chunks.count)"
            let began = Date()
            do {
                let result = try await synthesis.synthesizeChunkDetailed(
                    chunkText: chunks[index], voice: voice)
                guard !Task.isCancelled else { return }
                // The number that decides whether any of this works: how long a
                // chunk takes to synthesise versus how long it plays for. If
                // the first exceeds the second, playback can never keep ahead.
                log(String(
                    format: "chunk %d synthesised in %.1fs (plays %.1fs)",
                    index + 1, Date().timeIntervalSince(began), result.duration))
                guard let buffer = Self.pcmBuffer(fromWAV: result.data) else {
                    status = "Chunk \(index + 1) could not be decoded"
                    log("chunk \(index + 1) decode failed")
                    return
                }
                synthesisedDuration += result.duration
                synthesisedCharacters += chunks[index].count
                synthesisedChunks = index + 1
                refreshEstimate()
                schedule(buffer, at: index)
                index += 1
                status = "Playing \(playingChunk + 1)/\(chunks.count)"
            } catch {
                status = "Synthesis failed: \(error.localizedDescription)"
                log("SYNTHESIS FAILED at chunk \(index + 1): \(error)")
                return
            }
        }
        log("all chunks queued")
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, at index: Int) {
        if !isConnected {
            // Connected with the first buffer's own format so no conversion is
            // needed, and started only once there is something to render.
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            format = buffer.format
            engine.prepare()
            do {
                try engine.start()
            } catch {
                status = "Engine failed: \(error.localizedDescription)"
                log("engine start failed: \(error.localizedDescription)")
                return
            }
            isConnected = true
        }

        pendingBuffers += 1
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishedChunk(index) }
        }

        if !isPlaying {
            node.play()
            playingSince = Date()
            isPlaying = true
            log("playback started")
            updateNowPlaying()
        }
    }

    private func finishedChunk(_ index: Int) {
        pendingBuffers -= 1
        playingChunk = index + 1
        if index + 1 >= chunks.count {
            isFinished = true
            status = "Finished"
            log("finished all \(chunks.count) chunks")
            isPlaying = false
            accumulated = elapsedNow()
            playingSince = nil
        } else if pendingBuffers <= 0 {
            // Nothing left to render and more text to come: the node is about
            // to fall silent, which is what gets a backgrounded app suspended —
            // and once suspended synthesis stops too, so it can never catch up.
            // Silence holds the slot until the next chunk lands.
            log("STARVED at chunk \(index + 1) — synthesis fell behind")
            scheduleSilence()
        }
        updateNowPlaying()
    }

    /// Keeps the node rendering while synthesis catches up. Half a second at a
    /// time so playback resumes promptly once a real chunk is ready.
    private func scheduleSilence() {
        guard !isFinished, let format,
              let silence = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 2))
        else { return }
        silence.frameLength = silence.frameCapacity
        pendingBuffers += 1
        node.scheduleBuffer(silence, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingBuffers -= 1
                if self.pendingBuffers <= 0 { self.scheduleSilence() }
            }
        }
    }

    // MARK: - Time

    private func startTicker() {
        ticker?.invalidate()
        // 1Hz is enough for a readout and for Now Playing, which should be
        // written sparingly rather than on every frame.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.elapsed = self.elapsedNow()
                self.updateNowPlaying()
            }
        }
    }

    private func elapsedNow() -> TimeInterval {
        accumulated + (playingSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    private func refreshEstimate() {
        guard synthesisedCharacters > 0, totalCharacters > 0 else { return }
        estimatedDuration =
            synthesisedDuration / Double(synthesisedCharacters) * Double(totalCharacters)
    }

    // MARK: - Session and lock screen

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.longFormAudio` is the audiobook/podcast policy — it is what
            // makes this eligible for the system's long-form playback UI.
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
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "Background playback test"
        info[MPMediaItemPropertyArtist] = VoiceDisplayName.forCode(voice)
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedNow()
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if estimatedDuration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = estimatedDuration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - WAV decoding

    /// Kokoro hands back canonical 16-bit mono WAVs (see `WavConcatenator`),
    /// but this still walks the RIFF chunk list rather than assuming a 44-byte
    /// header, for the same reason that one does.
    private static func pcmBuffer(fromWAV wav: Data) -> AVAudioPCMBuffer? {
        let bytes = [UInt8](wav)
        guard bytes.count > 12,
              Array(bytes[0..<4]) == Array("RIFF".utf8),
              Array(bytes[8..<12]) == Array("WAVE".utf8)
        else { return nil }

        var offset = 12
        var sampleRate: Double = 0
        var channels = 0
        var bitsPerSample = 0
        var pcm: ArraySlice<UInt8>?

        while offset + 8 <= bytes.count {
            let identifier = Array(bytes[offset..<(offset + 4)])
            let size = Int(readUInt32LE(bytes, at: offset + 4))
            let body = offset + 8
            guard size >= 0, body + size <= bytes.count else { break }
            if identifier == Array("fmt ".utf8), size >= 16 {
                channels = Int(readUInt16LE(bytes, at: body + 2))
                sampleRate = Double(readUInt32LE(bytes, at: body + 4))
                bitsPerSample = Int(readUInt16LE(bytes, at: body + 14))
            } else if identifier == Array("data".utf8) {
                pcm = bytes[body..<(body + size)]
            }
            offset = body + size + (size % 2)  // RIFF chunks are word aligned
        }

        guard bitsPerSample == 16, channels > 0, sampleRate > 0, let pcm, !pcm.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels), interleaved: false)
        else { return nil }

        let frames = pcm.count / 2 / channels
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)

        let base = pcm.startIndex
        for frame in 0..<frames {
            for channel in 0..<channels {
                let index = base + (frame * channels + channel) * 2
                let raw = UInt16(pcm[index]) | (UInt16(pcm[index + 1]) << 8)
                channelData[channel][frame] = Float(Int16(bitPattern: raw)) / 32768
            }
        }
        return buffer
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
