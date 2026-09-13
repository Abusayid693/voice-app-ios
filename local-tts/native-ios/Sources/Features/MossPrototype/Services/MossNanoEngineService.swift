import Foundation
// The SPM *product* is "onnxruntime", but the importable module is the
// target backing it (`OnnxRuntimeBindings`, the compiled Objective-C
// wrapper) — targets define modules, products only define link units.
import OnnxRuntimeBindings

enum MossNanoEngineError: LocalizedError {
    case modelsMissing
    case noBuiltinVoice
    case emptyText
    case missingOutput(String)
    case emptyAudio
    case unexpectedShape(String)
    case coreMLUnavailable

    var errorDescription: String? {
        switch self {
        case .modelsMissing: return "MOSS-TTS-Nano models aren't downloaded yet."
        case .noBuiltinVoice: return "The manifest has no built-in voice with reference audio codes."
        case .emptyText: return "Enter some text to synthesize."
        case .missingOutput(let name): return "Missing ONNX output: \(name)"
        case .emptyAudio: return "No audio frames were generated."
        case .unexpectedShape(let detail): return "Unexpected tensor shape: \(detail)"
        case .coreMLUnavailable:
            return "This ONNX Runtime build has no CoreML execution provider, so there's no ANE path to measure."
        }
    }
}

/// Runs MOSS-TTS-Nano's text-to-speech pipeline via ONNX Runtime, ported
/// 1:1 from OpenMOSS's own Android reference implementation
/// (`examples/android_onnx_runtime/.../MossOnnxDemoEngine.kt` in
/// OpenMOSS/MOSS-TTS-Nano) rather than re-derived from the ONNX graphs —
/// that file is the one place upstream actually demonstrates a working
/// native on-device pipeline, including which of the 5 shipped TTS graphs
/// are real vs. unused. Of those 5, only `prefill`, `decode_step`, and
/// `local_fixed_sampled_frame` are ever called — `local_decoder` and
/// `local_cached_step` are dead weight in that same reference — plus the
/// audio-tokenizer's `decode_full` to turn RVQ codes into a waveform. See
/// the plan doc for the exact source read and tensor-name verification.
///
/// Text tokenization is a plain SentencePiece encode (`MossNanoTokenizer`)
/// — every MOSS-specific structural token (audio start/end, user/assistant
/// slot, padding) is a raw numeric ID from the manifest, spliced into the
/// fixed-width "rows" this model consumes, not part of the vocabulary.
final class MossNanoEngineService {
    private let prefillSession: ORTSession
    private let decodeSession: ORTSession
    private let localFixedFrameSession: ORTSession
    private let codecDecodeSession: ORTSession

    private let manifest: MossNanoManifest
    private let codecMeta: MossNanoCodecMeta
    private let tokenizer: MossNanoTokenizer

    // `decode_input_names` is ["input_ids", "past_valid_lengths", "past_key_0",
    // "past_value_0", ...]; `decode_output_names` is ["global_hidden",
    // "present_key_0", "present_value_0", ...]. Dropping the first 2 / 1
    // respectively lines the two lists up positionally — each decode
    // step's `present_*` output becomes the next step's matching `past_*`
    // input, exactly as the Android reference threads its KV cache.
    private let decodePastInputNames: [String]
    private let decodePresentOutputNames: [String]

    init(executionProvider: MossNanoExecutionProvider) throws {
        guard MossNanoModelDownloader.isDownloaded() else {
            throw MossNanoEngineError.modelsMissing
        }

        let env = try ORTEnv(loggingLevel: .warning)

        let ttsDir = MossNanoModelDownloader.ttsDirectory
        let codecDir = MossNanoModelDownloader.codecDirectory
        // Separate options per directory: each carries its own external-data
        // folder, and the TTS graphs and the codec graph keep their weights
        // in different folders.
        let ttsOptions = try Self.makeSessionOptions(
            executionProvider: executionProvider, externalDataFolder: ttsDir)
        let codecOptions = try Self.makeSessionOptions(
            executionProvider: executionProvider, externalDataFolder: codecDir)

        prefillSession = try ORTSession(
            env: env, modelPath: ttsDir.appendingPathComponent("moss_tts_prefill.onnx").path,
            sessionOptions: ttsOptions)
        decodeSession = try ORTSession(
            env: env, modelPath: ttsDir.appendingPathComponent("moss_tts_decode_step.onnx").path,
            sessionOptions: ttsOptions)
        localFixedFrameSession = try ORTSession(
            env: env,
            modelPath: ttsDir.appendingPathComponent("moss_tts_local_fixed_sampled_frame.onnx").path,
            sessionOptions: ttsOptions)
        codecDecodeSession = try ORTSession(
            env: env,
            modelPath: codecDir.appendingPathComponent("moss_audio_tokenizer_decode_full.onnx").path,
            sessionOptions: codecOptions)

        manifest = try JSONDecoder().decode(
            MossNanoManifest.self,
            from: Data(contentsOf: ttsDir.appendingPathComponent("browser_poc_manifest.json")))
        let ttsMeta = try JSONDecoder().decode(
            MossNanoTtsMeta.self,
            from: Data(contentsOf: ttsDir.appendingPathComponent("tts_browser_onnx_meta.json")))
        codecMeta = try JSONDecoder().decode(
            MossNanoCodecMeta.self,
            from: Data(contentsOf: codecDir.appendingPathComponent("codec_browser_onnx_meta.json")))

        decodePastInputNames = Array(ttsMeta.onnx.decodeInputNames.dropFirst(2))
        decodePresentOutputNames = Array(ttsMeta.onnx.decodeOutputNames.dropFirst(1))

        tokenizer = MossNanoTokenizer(modelPath: ttsDir.appendingPathComponent("tokenizer.model").path)
    }

    /// One-shot synthesis: builds the input rows, runs prefill once, loops
    /// the KV-cached decode step per audio frame until the model signals
    /// stop (or `maxFrames`), then decodes the accumulated RVQ codes to a
    /// waveform. Always uses the first built-in voice with reference audio
    /// codes — no voice picker yet, matching this prototype's scope.
    /// These models keep their weights in sibling `.data` files, referenced
    /// from inside the graph by bare filename. ORT was resolving those
    /// against the model *file* rather than its parent directory —
    /// producing `.../moss_tts_prefill.onnx/moss_tts_global_shared.data`
    /// and failing with "Not a directory" — so the folder is pinned
    /// explicitly here instead of being derived.
    private static func makeSessionOptions(
        executionProvider: MossNanoExecutionProvider, externalDataFolder: URL
    ) throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(4)
        try options.setGraphOptimizationLevel(.all)
        // Trailing slash: harmless if ORT joins paths properly, required if
        // it concatenates.
        try options.addConfigEntry(
            withKey: "session.model_external_initializers_file_folder_path",
            value: externalDataFolder.path + "/")

        if executionProvider == .coreMLANE {
            // Without this check a CoreML-less build would quietly run
            // everything on CPU and still report itself as the "ANE" run,
            // which would make the whole benchmark lie.
            guard ORTIsCoreMLExecutionProviderAvailable() else {
                throw MossNanoEngineError.coreMLUnavailable
            }
            let coreMLOptions = ORTCoreMLExecutionProviderOptions()
            coreMLOptions.onlyEnableForDevicesWithANE = true
            try options.appendCoreMLExecutionProvider(with: coreMLOptions)
        }
        return options
    }

    /// `maxFrames` defaults high enough to hit the manifest's own
    /// `max_new_frames` cap (375 frames at 12.5fps, i.e. ~30s of audio) —
    /// `runDecodeLoop` takes the min of the two, so the model's own limit
    /// is what actually binds. A long input therefore makes prefill
    /// expensive without lengthening the decode loop past that ceiling.
    func synthesize(text: String, maxFrames: Int = 375) throws -> MossNanoSynthesisResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MossNanoEngineError.emptyText }
        let textTokenIds = tokenizer.encode(trimmed)
        guard !textTokenIds.isEmpty else { throw MossNanoEngineError.emptyText }

        guard let promptVoice = manifest.builtinVoices.first(where: { !$0.promptAudioCodes.isEmpty }) else {
            throw MossNanoEngineError.noBuiltinVoice
        }

        let cfg = manifest.ttsConfig
        let rowWidth = cfg.nVq + 1

        let prefixTokens = manifest.promptTemplates.userPromptPrefixTokenIds + [cfg.audioStartTokenId]
        let suffixTokens =
            [cfg.audioEndTokenId] + manifest.promptTemplates.userPromptAfterReferenceTokenIds
            + textTokenIds + manifest.promptTemplates.assistantPromptPrefixTokenIds
            + [cfg.audioStartTokenId]

        var rows: [[Int32]] = []
        rows += buildTextRows(prefixTokens, cfg: cfg, rowWidth: rowWidth)
        rows += buildAudioRows(promptVoice.promptAudioCodes, cfg: cfg, rowWidth: rowWidth)
        rows += buildTextRows(suffixTokens, cfg: cfg, rowWidth: rowWidth)

        let overallStart = Date()

        let prefillStart = Date()
        let prefill = try runPrefill(rows: rows, rowWidth: rowWidth)
        let prefillSeconds = Date().timeIntervalSince(prefillStart)

        let decodeStart = Date()
        let audioTokens = try runDecodeLoop(
            cfg: cfg, rowWidth: rowWidth, maxFrames: maxFrames, prefill: prefill)
        let decodeLoopSeconds = Date().timeIntervalSince(decodeStart)

        guard !audioTokens.isEmpty else { throw MossNanoEngineError.emptyAudio }

        let codecStart = Date()
        let (pcm, sampleRate) = try decodeAudioTokens(audioTokens, nVq: cfg.nVq)
        let codecDecodeSeconds = Date().timeIntervalSince(codecStart)
        let totalSeconds = Date().timeIntervalSince(overallStart)

        var timings = MossNanoTimings()
        timings.prefillSeconds = prefillSeconds
        timings.decodeLoopSeconds = decodeLoopSeconds
        timings.codecDecodeSeconds = codecDecodeSeconds
        timings.totalSeconds = totalSeconds
        timings.frameCount = audioTokens.count
        timings.audioDurationSeconds = Double(pcm.count) / Double(sampleRate)

        return MossNanoSynthesisResult(pcm: pcm, sampleRate: sampleRate, timings: timings)
    }

    // MARK: - Row building

    private func buildTextRows(_ tokens: [Int], cfg: MossNanoManifest.TtsConfig, rowWidth: Int) -> [[Int32]] {
        tokens.map { token in
            var row = [Int32](repeating: Int32(cfg.audioPadTokenId), count: rowWidth)
            row[0] = Int32(token)
            return row
        }
    }

    private func buildAudioRows(_ codes: [[Int]], cfg: MossNanoManifest.TtsConfig, rowWidth: Int) -> [[Int32]] {
        codes.map { codeRow in
            var row = [Int32](repeating: Int32(cfg.audioPadTokenId), count: rowWidth)
            row[0] = Int32(cfg.audioUserSlotTokenId)
            for index in 0..<min(codeRow.count, cfg.nVq) {
                row[index + 1] = Int32(codeRow[index])
            }
            return row
        }
    }

    // MARK: - Prefill

    private struct PrefillState {
        var globalHidden: ORTValue
        var pastResult: [String: ORTValue]
        var pastValidLengths: Int32
    }

    private func runPrefill(rows: [[Int32]], rowWidth: Int) throws -> PrefillState {
        let seqLen = rows.count
        var inputIdsFlat = [Int32]()
        inputIdsFlat.reserveCapacity(seqLen * rowWidth)
        for row in rows { inputIdsFlat.append(contentsOf: row) }
        let attentionMask = [Int32](repeating: 1, count: seqLen)

        let inputIdsTensor = try MossNanoTensor.makeInt32(inputIdsFlat, shape: [1, seqLen, rowWidth])
        let maskTensor = try MossNanoTensor.makeInt32(attentionMask, shape: [1, seqLen])

        let outputNames = Set(["global_hidden"] + decodePresentOutputNames)
        let outputs = try prefillSession.run(
            withInputs: ["input_ids": inputIdsTensor, "attention_mask": maskTensor],
            outputNames: outputNames, runOptions: nil)
        guard let globalHiddenRaw = outputs["global_hidden"] else {
            throw MossNanoEngineError.missingOutput("global_hidden")
        }
        return PrefillState(
            globalHidden: try extractLastHidden(globalHiddenRaw),
            pastResult: outputs,
            pastValidLengths: Int32(seqLen))
    }

    // MARK: - Decode loop

    private func runDecodeLoop(
        cfg: MossNanoManifest.TtsConfig, rowWidth: Int, maxFrames: Int, prefill: PrefillState
    ) throws -> [[Int32]] {
        var globalHidden = prefill.globalHidden
        var pastResult = prefill.pastResult
        var pastValidLengths = prefill.pastValidLengths

        var previousTokenSets = [Set<Int32>](repeating: [], count: cfg.nVq)
        let codebookSize = cfg.audioCodebookSizes.first ?? 1024
        let cappedMaxFrames = min(maxFrames, manifest.generationDefaults.maxNewFrames)
        var audioTokens: [[Int32]] = []

        let decodeOutputNames = Set(["global_hidden"] + decodePresentOutputNames)

        for _ in 0..<cappedMaxFrames {
            let frame = try runLocalFixedSampledFrame(
                globalHidden: globalHidden, previousTokenSets: previousTokenSets,
                nVq: cfg.nVq, codebookSize: codebookSize)
            guard frame.shouldContinue else { break }

            var audioRow = [Int32](repeating: Int32(cfg.audioPadTokenId), count: rowWidth)
            audioRow[0] = Int32(cfg.audioAssistantSlotTokenId)
            for channel in 0..<cfg.nVq {
                let token = frame.tokens[channel]
                audioRow[channel + 1] = token
                previousTokenSets[channel].insert(token)
            }
            audioTokens.append(Array(frame.tokens.prefix(cfg.nVq)))

            let stepInputTensor = try MossNanoTensor.makeInt32(audioRow, shape: [1, 1, rowWidth])
            let pastLengthsTensor = try MossNanoTensor.makeInt32([pastValidLengths], shape: [1])

            var feeds: [String: ORTValue] = [
                "input_ids": stepInputTensor,
                "past_valid_lengths": pastLengthsTensor,
            ]
            for (pastName, presentName) in zip(decodePastInputNames, decodePresentOutputNames) {
                guard let cached = pastResult[presentName] else {
                    throw MossNanoEngineError.missingOutput(presentName)
                }
                feeds[pastName] = cached
            }

            let outputs = try decodeSession.run(
                withInputs: feeds, outputNames: decodeOutputNames, runOptions: nil)
            guard let nextGlobalHidden = outputs["global_hidden"] else {
                throw MossNanoEngineError.missingOutput("global_hidden")
            }
            globalHidden = try extractLastHidden(nextGlobalHidden)
            pastResult = outputs
            pastValidLengths += 1
        }
        return audioTokens
    }

    private struct LocalFrameResult {
        let shouldContinue: Bool
        let tokens: [Int32]
    }

    private func runLocalFixedSampledFrame(
        globalHidden: ORTValue, previousTokenSets: [Set<Int32>], nVq: Int, codebookSize: Int
    ) throws -> LocalFrameResult {
        var seenMask = [Int32](repeating: 0, count: nVq * codebookSize)
        for channel in 0..<previousTokenSets.count {
            let offset = channel * codebookSize
            for token in previousTokenSets[channel] where token >= 0 && Int(token) < codebookSize {
                seenMask[offset + Int(token)] = 1
            }
        }
        let epsilon: Float = 1e-6
        let assistantRandom: [Float] = [Float.random(in: epsilon...(1 - epsilon))]
        let audioRandom: [Float] = (0..<nVq).map { _ in Float.random(in: epsilon...(1 - epsilon)) }

        let seenTensor = try MossNanoTensor.makeInt32(seenMask, shape: [1, nVq, codebookSize])
        let assistantTensor = try MossNanoTensor.makeFloat(assistantRandom, shape: [1])
        let audioTensor = try MossNanoTensor.makeFloat(audioRandom, shape: [1, nVq])

        let outputs = try localFixedFrameSession.run(
            withInputs: [
                "global_hidden": globalHidden,
                "repetition_seen_mask": seenTensor,
                "assistant_random_u": assistantTensor,
                "audio_random_u": audioTensor,
            ],
            outputNames: ["should_continue", "frame_token_ids"], runOptions: nil)

        guard let continueValue = outputs["should_continue"], let frameValue = outputs["frame_token_ids"] else {
            throw MossNanoEngineError.missingOutput("frame_token_ids")
        }
        let shouldContinue = (try MossNanoTensor.intArray(from: continueValue).first ?? 0) > 0
        let tokens = try MossNanoTensor.intArray(from: frameValue).map(Int32.init)
        return LocalFrameResult(shouldContinue: shouldContinue, tokens: tokens)
    }

    /// `global_hidden` comes back as either `[1, hidden]` (already the
    /// single relevant position) or `[1, seqLen, hidden]` (prefill's full
    /// sequence) — only the last position feeds the next step, matching
    /// the Android reference's `extractLastHiddenTensor`.
    private func extractLastHidden(_ tensor: ORTValue) throws -> ORTValue {
        let shape = try MossNanoTensor.shape(of: tensor)
        let flat = try MossNanoTensor.floatArray(from: tensor)
        switch shape.count {
        case 2:
            return try MossNanoTensor.makeFloat(flat, shape: [1, shape[1]])
        case 3:
            let hidden = shape[2]
            let lastStart = (shape[1] - 1) * hidden
            let lastHidden = Array(flat[lastStart..<(lastStart + hidden)])
            return try MossNanoTensor.makeFloat(lastHidden, shape: [1, hidden])
        default:
            throw MossNanoEngineError.unexpectedShape("global_hidden rank \(shape.count)")
        }
    }

    // MARK: - Codec decode

    private func decodeAudioTokens(_ audioTokens: [[Int32]], nVq: Int) throws -> (pcm: [Float], sampleRate: Int) {
        let numFrames = audioTokens.count
        var codesFlat = [Int32]()
        codesFlat.reserveCapacity(numFrames * nVq)
        for frame in audioTokens { codesFlat.append(contentsOf: frame) }

        let codesTensor = try MossNanoTensor.makeInt32(codesFlat, shape: [1, numFrames, nVq])
        let lengthsTensor = try MossNanoTensor.makeInt32([Int32(numFrames)], shape: [1])

        let outputs = try codecDecodeSession.run(
            withInputs: ["audio_codes": codesTensor, "audio_code_lengths": lengthsTensor],
            outputNames: ["audio", "audio_lengths"], runOptions: nil)

        guard let audioValue = outputs["audio"], let lengthsValue = outputs["audio_lengths"] else {
            throw MossNanoEngineError.missingOutput("audio")
        }

        let audioShape = try MossNanoTensor.shape(of: audioValue)
        guard audioShape.count == 3 else {
            throw MossNanoEngineError.unexpectedShape("audio rank \(audioShape.count)")
        }
        let channels = audioShape[1]
        let samplesPerChannel = audioShape[2]
        let flatAudio = try MossNanoTensor.floatArray(from: audioValue)
        let reportedLength = try MossNanoTensor.intArray(from: lengthsValue).first ?? 0
        let length = min(reportedLength > 0 ? reportedLength : samplesPerChannel, samplesPerChannel)
        guard length > 0 else { throw MossNanoEngineError.emptyAudio }

        // Downmix stereo -> mono, matching the Android reference (simplest
        // path for a benchmark tool; true stereo output is a follow-up).
        var mono = [Float](repeating: 0, count: length)
        for sampleIndex in 0..<length {
            var sum: Float = 0
            for channel in 0..<channels {
                sum += flatAudio[channel * samplesPerChannel + sampleIndex]
            }
            mono[sampleIndex] = sum / Float(channels)
        }
        return (mono, codecMeta.codecConfig.sampleRate)
    }
}
