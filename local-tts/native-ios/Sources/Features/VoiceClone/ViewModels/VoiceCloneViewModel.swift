import AVFoundation
import FluidAudio
import Foundation

/// Recording + cloning + managing the user's own cloned voices — a
/// separate concern from TTSViewModel's TTS-generation orchestration, so
/// it gets its own ViewModel rather than growing that one further. Owns
/// its own PocketEngineService instance (wrapping the same shared
/// PocketTtsManager/AVAudioEngine/AVAudioPlayerNode from
/// DependencyContainer as TTSViewModel's) — safe, since PocketEngineService
/// holds no state of its own beyond those shared references.
@MainActor
final class VoiceCloneViewModel: ObservableObject {
    @Published private(set) var clonedVoices: [ClonedVoice] = []

    // Recording (see VoiceRecorderService)
    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var hasRecording = false
    @Published private(set) var isPreviewingRecording = false
    // True when the current sample came from importAudio(from:) rather
    // than the mic — RecordVoiceView uses this to show "Imported file"
    // instead of a recording timer that was never actually counting.
    @Published private(set) var isImportedSample = false

    // Cloning the current recording into a saved ClonedVoice
    @Published private(set) var isCloning = false
    @Published var cloneErrorMessage: String?

    // Live preview playback of an already-cloned, saved voice (no bundled
    // clip exists for these — they're user-specific — so this actually
    // synthesizes a short line through the cloned voice each time).
    @Published private(set) var previewingVoiceID: UUID?
    @Published private(set) var isPreviewLoading = false

    private static let previewLine = "Hi, this is what your cloned voice sounds like."
    private static let clonedVoicesDefaultsKey = "clonedVoices"
    private static let maxRecordingDuration: TimeInterval = 20

    private let pocketService: PocketEngineService
    private let recorder = VoiceRecorderService()
    private var recordingTimerTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var pocketModelsReady = false

    init(dependencies: DependencyContainer) {
        pocketService = PocketEngineService(
            manager: dependencies.pocketManager,
            audioEngine: dependencies.audioEngine,
            playerNode: dependencies.playerNode,
            streamFormat: dependencies.streamFormat)
        clonedVoices = Self.loadMetadata()
    }

    // MARK: - Recording

    func startRecording() {
        do {
            try recorder.startRecording()
            isRecording = true
            hasRecording = false
            isImportedSample = false
            recordingDuration = 0
            cloneErrorMessage = nil
            recordingTimerTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { return }
                    self.recordingDuration += 0.1
                    if self.recordingDuration >= Self.maxRecordingDuration {
                        self.stopRecording()
                        return
                    }
                }
            }
        } catch {
            cloneErrorMessage = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recorder.stopRecording()
        isRecording = false
        hasRecording = true
    }

    func discardRecording() {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recorder.stopPreview()
        recorder.discardRecording()
        isRecording = false
        hasRecording = false
        recordingDuration = 0
        isPreviewingRecording = false
        isImportedSample = false
    }

    func previewRecording() {
        guard hasRecording, !isPreviewingRecording else { return }
        isPreviewingRecording = true
        recorder.playPreview { [weak self] in
            Task { @MainActor in self?.isPreviewingRecording = false }
        }
    }

    /// Alternative to recording — pick an existing audio file instead.
    /// Transcodes it to the same temp WAV location a recording would use,
    /// so everything downstream (preview, clone) treats the two the same.
    func importAudio(from url: URL) {
        discardRecording()
        do {
            try recorder.importAudioFile(from: url)
            hasRecording = true
            isImportedSample = true
        } catch {
            cloneErrorMessage = "Couldn't import that file: \(error.localizedDescription)"
        }
    }

    // MARK: - Cloning

    func cloneAndSave(name: String) async {
        guard let sampleURL = recorder.currentRecordingURL else { return }
        isCloning = true
        cloneErrorMessage = nil
        defer { isCloning = false }
        do {
            let voiceData = try await pocketService.cloneVoice(from: sampleURL)
            let voice = ClonedVoice(id: UUID(), name: name, createdAt: Date())
            try pocketService.saveClonedVoice(voiceData, to: voice.fileURL)
            clonedVoices.append(voice)
            Self.saveMetadata(clonedVoices)
            discardRecording()
        } catch {
            cloneErrorMessage = "Couldn't clone this voice: \(error.localizedDescription)"
        }
    }

    func deleteVoice(_ voice: ClonedVoice) {
        if previewingVoiceID == voice.id { stopPreview() }
        clonedVoices.removeAll { $0.id == voice.id }
        Self.saveMetadata(clonedVoices)
        try? FileManager.default.removeItem(at: voice.fileURL)
    }

    // MARK: - Preview playback of a saved cloned voice

    func togglePreview(for voice: ClonedVoice) {
        if previewingVoiceID == voice.id {
            stopPreview()
            return
        }
        stopPreview()
        previewingVoiceID = voice.id
        isPreviewLoading = true
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !self.pocketModelsReady {
                    try await self.pocketService.ensureModels(progressHandler: nil)
                    try await self.pocketService.initialize()
                    self.pocketModelsReady = true
                }
                let voiceData = try self.pocketService.loadClonedVoice(from: voice.fileURL)
                try self.pocketService.preparePlayback()
                let stream = try await self.pocketService.synthesizeStreaming(
                    text: Self.previewLine, voiceData: voiceData)
                var receivedFirstFrame = false
                for try await frame in stream {
                    guard !Task.isCancelled, self.previewingVoiceID == voice.id else { break }
                    if !receivedFirstFrame {
                        receivedFirstFrame = true
                        self.isPreviewLoading = false
                    }
                    self.pocketService.schedule(frame)
                }
            } catch {
                self.cloneErrorMessage = "Couldn't preview this voice: \(error.localizedDescription)"
            }
            if self.previewingVoiceID == voice.id {
                self.previewingVoiceID = nil
                self.isPreviewLoading = false
            }
        }
    }

    func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        pocketService.stopPlayback()
        previewingVoiceID = nil
        isPreviewLoading = false
    }

    // MARK: - Persistence (metadata only — binaries live at ClonedVoice.fileURL)

    private static func loadMetadata() -> [ClonedVoice] {
        guard let data = UserDefaults.standard.data(forKey: clonedVoicesDefaultsKey),
            let voices = try? JSONDecoder().decode([ClonedVoice].self, from: data)
        else { return [] }
        return voices
    }

    private static func saveMetadata(_ voices: [ClonedVoice]) {
        guard let data = try? JSONEncoder().encode(voices) else { return }
        UserDefaults.standard.set(data, forKey: clonedVoicesDefaultsKey)
    }
}
