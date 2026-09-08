import AVFoundation
import FluidAudio
import SwiftUI

private enum Engine: String, CaseIterable {
    case kokoroAne = "Kokoro-ANE"
    case pocketTts = "PocketTTS"
}

struct ContentView: View {
    // Only af_heart is currently published in the ANE HF repo; the rest of
    // the standard Kokoro-82M English voice set is listed for testing, but
    // will fail to download until FluidAudio publishes them there.
    private static let kokoroVoices = [
        "af_alloy", "af_aoede", "af_bella", "af_heart", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    // All 26 published in constants_bin/ for the English v2.1 pack — these
    // are real, no missing-asset gap like the Kokoro voices above.
    private static let pocketVoices = [
        "alba", "anna", "azelma", "bill_boerst", "caro_davy", "charles",
        "cosette", "eponine", "estelle", "eve", "fantine", "george", "giovanni",
        "jane", "javert", "jean", "juergen", "lola", "marius", "mary", "michael",
        "paul", "peter_yearsley", "rafael", "stuart_bell", "vera",
    ]

    @State private var engine: Engine = .kokoroAne
    @State private var kokoroVoice = "af_heart"
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

    private let kokoroManager = KokoroAneManager()
    // .ane keeps the FlowLM + conditioning prefill on the Neural Engine
    // (rank-4 flowlm_step_ane/cond_prefill_ane) instead of GPU — the SDK
    // defaults to .gpu, but that default is benchmarked on M-series Macs;
    // .ane is documented as the iOS-appropriate placement. Precision is
    // ignored under .ane (those variants are fp16-only).
    private let pocketManager = PocketTtsManager(language: .english, placement: .ane)
    @State private var audioPlayer: AVAudioPlayer?

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
                        Picker("Voice", selection: $kokoroVoice) {
                            ForEach(Self.kokoroVoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .disabled(isBusy)
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
                    TextField("Text to speak", text: $text, axis: .vertical)
                        .lineLimit(3...6)
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

                    if !isWarmInit, isBusy, initSeconds == nil {
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
                    if let synthSeconds {
                        LabeledContent("Synthesis") {
                            Text(String(format: "%.2fs", synthSeconds))
                        }
                    }
                }
            }
            .navigationTitle("FluidAudio TTS Test")
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
        isBusy = true
        downloadFraction = 0
        downloadedBytes = 0
        totalBytes = nil
        downloadFileProgress = nil
        initSeconds = nil
        synthSeconds = nil
    }

    private func runKokoroAne() {
        resetRunState()
        let voice = kokoroVoice

        Task {
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)

                let wasAvailable = await kokoroManager.isAvailable()
                isWarmInit = wasAvailable

                let initStart = Date()
                if wasAvailable {
                    status = "Loading…"
                } else {
                    status = "Fetching model size…"
                    totalBytes = await fetchEnglishKokoroTotalBytes()

                    status = "Downloading model…"
                    // Pre-download with progress reporting, then hand off to
                    // manager.initialize() — it will find the files already
                    // cached and skip straight to the (fast) load step.
                    try await KokoroAneResourceDownloader.ensureModels(
                        variant: .english,
                        progressHandler: { progress in
                            Task { @MainActor in
                                // Repo downloads reserve 0-0.5 of the fraction
                                // for a CoreML compile phase that never fires
                                // for these pre-compiled .mlmodelc bundles.
                                self.applyDownloadProgress(progress, phaseWeight: 0.5)
                            }
                        })
                }

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

                let wasAvailable = await pocketManager.isAvailable
                isWarmInit = wasAvailable

                let initStart = Date()
                if wasAvailable {
                    status = "Loading…"
                } else {
                    status = "Fetching model size…"
                    totalBytes = await fetchPocketTtsTotalBytes()

                    status = "Downloading model…"
                    try await PocketTtsResourceDownloader.ensureModels(
                        language: .english,
                        placement: .ane,
                        progressHandler: { progress in
                            Task { @MainActor in
                                // Subdirectory downloads (PocketTTS's language
                                // packs) span the whole 0...1 fraction — no
                                // separate compile phase to reserve room for.
                                self.applyDownloadProgress(progress, phaseWeight: 1.0)
                            }
                        })
                }

                status = "Loading models…"
                try await pocketManager.initialize()
                initSeconds = Date().timeIntervalSince(initStart)

                status = "Synthesizing…"
                let synthStart = Date()
                let data = try await pocketManager.synthesize(text: text, voice: voice)
                synthSeconds = Date().timeIntervalSince(synthStart)

                try playWav(data)
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

    @MainActor
    private func applyDownloadProgress(_ progress: DownloadProgress, phaseWeight: Double) {
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

#Preview {
    ContentView()
}
