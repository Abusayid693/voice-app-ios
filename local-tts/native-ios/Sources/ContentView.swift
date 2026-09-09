import AVFoundation
import FluidAudio
import SwiftUI

private enum Engine: String, CaseIterable {
    case kokoroAne = "Kokoro-ANE"
    case pocketTts = "PocketTTS"
}

struct ContentView: View {
    // af_heart is the only voice published in the ANE HF repo — the SDK's
    // own docs confirm this is a hard model-conversion constraint (the
    // compiled PostAlbert/Prosody/Noise/Vocoder stages are tied to this
    // voice's embedding), not just a missing download, so there's nothing
    // else worth offering here.
    private static let kokoroVoice = "af_heart"

    // All 26 published in constants_bin/ for the English v2.1 pack — these
    // are real, no missing-asset gap like the Kokoro voices above.
    private static let pocketVoices = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "estelle", "eve", "fantine", "george", "giovanni",
        "jane", "javert", "jean", "juergen", "lola", "marius", "mary", "michael",
        "paul", "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    @State private var engine: Engine = .kokoroAne
    @State private var pocketVoice = "alba"
    @State private var text = "Hello from FluidAudio!"
    @State private var status = "Idle"
    @State private var isBusy = false
    @State private var initSeconds: TimeInterval?
    @State private var synthSeconds: TimeInterval?
    @State private var isWarmInit = false

    @State private var downloadFraction: Double = 0
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64?
    @State private var downloadFileProgress: String?
    // Set only once a real download event fires (see applyDownloadProgress).
    // Models persist on disk across app launches (FluidAudio caches them in
    // Application Support), so `ensureModels()` is cheap and network-free on
    // a fresh launch even though nothing is loaded into this process's RAM
    // yet — gating the download UI on this instead of an in-memory
    // "isAvailable" flag keeps it from showing a fake "Downloading…" for
    // what's actually just a fast on-disk load.
    @State private var didDownload = false

    @State private var timeToFirstAudio: TimeInterval?
    @State private var streamChunkProgress: String?
    @State private var isTextSheetPresented = false

    private let kokoroManager = KokoroAneManager()
    // .ane keeps the FlowLM + conditioning prefill on the Neural Engine
    // (rank-4 flowlm_step_ane/cond_prefill_ane) instead of GPU — the SDK
    // defaults to .gpu, but that default is benchmarked on M-series Macs;
    // .ane is documented as the iOS-appropriate placement. Precision is
    // ignored under .ane (those variants are fp16-only).
    private let pocketManager = PocketTtsManager(language: .english, placement: .ane)
    @State private var audioPlayer: AVAudioPlayer?

    // PocketTTS streams 80ms frames rather than one complete WAV, so
    // playback goes through AVAudioEngine/AVAudioPlayerNode (which accepts
    // buffers incrementally) instead of AVAudioPlayer (which needs the
    // whole file up front).
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let streamFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(PocketTtsConstants.audioSampleRate),
        channels: 1,
        interleaved: false)!

    var body: some View {
        NavigationStack {
            Form {
                Section("Engine") {
                    Picker("Engine", selection: $engine) {
                        ForEach(Engine.allCases, id: \.self) { engine in
                            Text(engine.rawValue).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isBusy)
                }

                Section("Voice") {
                    switch engine {
                    case .kokoroAne:
                        LabeledContent("Voice", value: Self.kokoroVoice)
                    case .pocketTts:
                        Picker("Voice", selection: $pocketVoice) {
                            ForEach(Self.pocketVoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(isBusy)
                    }
                }

                Section("Text") {
                    Button {
                        isTextSheetPresented = true
                    } label: {
                        HStack {
                            Text(text.isEmpty ? "Tap to enter text" : text)
                                .foregroundStyle(text.isEmpty ? .secondary : .primary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                                .font(.caption)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    Button(action: runDownloadAndSpeak) {
                        if isBusy {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Download & Speak")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isBusy || text.isEmpty)
                }

                Section("Status") {
                    LabeledContent("State", value: status)

                    if didDownload, isBusy, initSeconds == nil {
                        ProgressView(value: downloadFraction)
                        LabeledContent("Downloaded") {
                            Text(downloadProgressLabel)
                        }
                        if let downloadFileProgress {
                            LabeledContent("Files", value: downloadFileProgress)
                        }
                    }

                    if let initSeconds {
                        LabeledContent(isWarmInit ? "Init (warm)" : "Init (cold, incl. download)") {
                            Text(String(format: "%.2fs", initSeconds))
                        }
                    }
                    if let timeToFirstAudio {
                        LabeledContent("Time to first audio") {
                            Text(String(format: "%.2fs", timeToFirstAudio))
                        }
                    }
                    if let streamChunkProgress {
                        LabeledContent("Chunk", value: streamChunkProgress)
                    }
                    if let synthSeconds {
                        LabeledContent("Synthesis") {
                            Text(String(format: "%.2fs", synthSeconds))
                        }
                    }
                }
            }
            .navigationTitle("FluidAudio TTS Test")
        }
        .fullScreenCover(isPresented: $isTextSheetPresented) {
            TextEntrySheet(
                text: $text,
                isBusy: isBusy,
                onListen: runDownloadAndSpeak,
                onClose: { isTextSheetPresented = false }
            )
        }
    }

    private var downloadProgressLabel: String {
        let downloaded = Self.formatMB(downloadedBytes)
        guard let totalBytes else { return "\(downloaded) MB" }
        return "\(downloaded) / \(Self.formatMB(totalBytes)) MB"
    }

    private static func formatMB(_ bytes: Int64) -> String {
        String(format: "%.0f", Double(bytes) / 1_048_576)
    }

    private func runDownloadAndSpeak() {
        switch engine {
        case .kokoroAne:
            runKokoroAne()
        case .pocketTts:
            runPocketTts()
        }
    }

    private func resetRunState() {
        stopAllPlayback()
        isBusy = true
        downloadFraction = 0
        downloadedBytes = 0
        totalBytes = nil
        downloadFileProgress = nil
        initSeconds = nil
        synthSeconds = nil
        timeToFirstAudio = nil
        streamChunkProgress = nil
        didDownload = false
    }

    private func stopAllPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        playerNode.stop()
    }

    private func runKokoroAne() {
        resetRunState()
        let voice = Self.kokoroVoice

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                // ensureModels() checks the on-disk cache first — if this
                // engine was already downloaded in a previous app launch,
                // this returns almost instantly with no network activity at
                // all, and the progress handler below never fires.
                try await KokoroAneResourceDownloader.ensureModels(
                    variant: .english,
                    progressHandler: { progress in
                        Task { @MainActor in
                            // Repo downloads reserve 0-0.5 of the fraction
                            // for a CoreML compile phase that never fires
                            // for these pre-compiled .mlmodelc bundles.
                            self.applyDownloadProgress(
                                progress, phaseWeight: 0.5, fetchTotal: self.fetchEnglishKokoroTotalBytes)
                        }
                    })
                isWarmInit = !didDownload

                status = "Loading models…"
                try await kokoroManager.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing…"
                let synthStart = Date()
                let data = try await kokoroManager.synthesize(text: text, voice: voice)
                synthSeconds = Date().timeIntervalSince(synthStart)

                try playWav(data)
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func runPocketTts() {
        resetRunState()
        let voice = pocketVoice

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                status = "Checking cache…"
                let initStart = Date()
                try await PocketTtsResourceDownloader.ensureModels(
                    language: .english,
                    placement: .ane,
                    progressHandler: { progress in
                        Task { @MainActor in
                            // Subdirectory downloads (PocketTTS's language
                            // packs) span the whole 0...1 fraction — no
                            // separate compile phase to reserve room for.
                            self.applyDownloadProgress(
                                progress, phaseWeight: 1.0, fetchTotal: self.fetchPocketTtsTotalBytes)
                        }
                    })
                isWarmInit = !didDownload

                status = "Loading models…"
                try await pocketManager.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing (streaming)…"
                try preparePlaybackEngine()
                playerNode.play()

                let synthStart = Date()
                let stream = try await pocketManager.synthesizeStreaming(text: text, voice: voice)
                var receivedFirstFrame = false
                for try await frame in stream {
                    if !receivedFirstFrame {
                        receivedFirstFrame = true
                        timeToFirstAudio = Date().timeIntervalSince(synthStart)
                        status = "Playing (streaming)…"
                    }
                    streamChunkProgress = "\(frame.chunkIndex + 1) / \(frame.chunkCount)"
                    schedule(frame)
                }
                synthSeconds = Date().timeIntervalSince(synthStart)
                status = "Idle"
            } catch {
                status = "Error: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private func playWav(_ data: Data) throws {
        status = "Playing"
        let player = try AVAudioPlayer(data: data)
        audioPlayer = player
        player.play()
    }

    private func preparePlaybackEngine() throws {
        if !audioEngine.attachedNodes.contains(playerNode) {
            audioEngine.attach(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: streamFormat)
        }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }

    /// Converts one 80ms `AudioFrame` (raw Float32 samples) into a PCM
    /// buffer and hands it to the player node — scheduling returns
    /// immediately, so playback runs concurrently with the next frame's
    /// generation rather than waiting for the whole utterance.
    private func schedule(_ frame: PocketTtsSynthesizer.AudioFrame) {
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(frame.samples.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frame.samples.count)
        frame.samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        playerNode.scheduleBuffer(buffer)
    }

    @MainActor
    private func applyDownloadProgress(
        _ progress: DownloadProgress, phaseWeight: Double, fetchTotal: @escaping () async -> Int64?
    ) {
        if !didDownload {
            didDownload = true
            Task { @MainActor in totalBytes = await fetchTotal() }
        }
        downloadFraction = min(1, progress.fractionCompleted / phaseWeight)
        if let totalBytes {
            downloadedBytes = Int64(downloadFraction * Double(totalBytes))
        }
        switch progress.phase {
        case .listing:
            status = "Listing model files…"
        case .downloading(let completedFiles, let totalFiles):
            status = "Downloading model…"
            downloadFileProgress = "\(completedFiles) / \(totalFiles)"
        case .compiling:
            status = "Compiling…"
        }
    }

    /// Sums file sizes from HuggingFace's public tree API for the English
    /// Kokoro-ANE bundle (`FluidInference/kokoro-82m-coreml/ANE`) — the SDK's
    /// own progress callback reports a fraction, not byte totals, so this is
    /// a best-effort, independent lookup purely for the "total size" display.
    private func fetchEnglishKokoroTotalBytes() async -> Int64? {
        await fetchTotalBytes(
            url: "https://huggingface.co/api/models/FluidInference/kokoro-82m-coreml/tree/main/ANE?recursive=true",
            matching: { _ in true })
    }

    /// Same idea, for PocketTTS's English v2.1 pack — but that directory also
    /// holds the GPU-placement/int8 variants, the MLState package, and the
    /// uncompiled `.mlpackage` sources, none of which `ensureModels(placement:
    /// .ane)` actually downloads. Filtering to just the components that call
    /// fetches keeps the total honest.
    private func fetchPocketTtsTotalBytes() async -> Int64? {
        let required = [
            "v2.1/english/cond_prefill_ane.mlmodelc/",
            "v2.1/english/flowlm_step_ane.mlmodelc/",
            "v2.1/english/flow_decoder_fused.mlmodelc/",
            "v2.1/english/mimi_decoder.mlmodelc/",
            "v2.1/english/constants_bin/",
        ]
        return await fetchTotalBytes(
            url: "https://huggingface.co/api/models/FluidInference/pocket-tts-coreml/tree/main/v2.1/english?recursive=true",
            matching: { path in required.contains { path.hasPrefix($0) } })
    }

    private func fetchTotalBytes(url: String, matching: @escaping (String) -> Bool) async -> Int64? {
        guard let url = URL(string: url) else { return nil }
        struct Entry: Decodable {
            let type: String
            let size: Int64?
            let path: String
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let entries = try JSONDecoder().decode([Entry].self, from: data)
            return entries
                .filter { $0.type == "file" && matching($0.path) }
                .reduce(0) { $0 + ($1.size ?? 0) }
        } catch {
            return nil
        }
    }
}

private struct TextEntrySheet: View {
    @Binding var text: String
    var isBusy: Bool
    var onListen: () -> Void
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.title3)
                .padding(4)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: onListen) {
                            if isBusy {
                                ProgressView()
                            } else {
                                Label("Listen", systemImage: "waveform")
                            }
                        }
                        .disabled(isBusy || text.isEmpty)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
