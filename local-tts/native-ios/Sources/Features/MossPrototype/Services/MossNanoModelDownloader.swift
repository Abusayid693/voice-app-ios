import Foundation

typealias MossNanoProgressHandler = (Double) -> Void

enum MossNanoDownloadError: LocalizedError {
    case invalidURL(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let file): return "Invalid URL for \(file)"
        case .badResponse(let file): return "Failed to download \(file)"
        }
    }
}

/// Downloads MOSS-TTS-Nano's ONNX artifacts into Application Support —
/// same rationale as Pocket TTS's runtime download (docs/adr/0007), just
/// hand-rolled since this is the app's first non-FluidAudio download.
///
/// Required-file lists and sizes below were verified directly against the
/// real HuggingFace repos (see the plan doc), not assumed. Progress is
/// reported per-file (coarse), not per-byte — the two `.data` weight files
/// dominate total size, so that's granular enough for a benchmark tool.
enum MossNanoModelDownloader {
    private static let ttsRepo = "https://huggingface.co/OpenMOSS-Team/MOSS-TTS-Nano-100M-ONNX/resolve/main"
    private static let codecRepo =
        "https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX/resolve/main"

    // Sizes are the real byte counts from each repo's file listing — used
    // only to weight the progress fraction across files of wildly
    // different size, not a correctness dependency.
    private static let ttsFiles: [(name: String, bytes: Int64)] = [
        ("moss_tts_prefill.onnx", 283_000),
        ("moss_tts_decode_step.onnx", 291_000),
        ("moss_tts_local_fixed_sampled_frame.onnx", 471_000),
        ("moss_tts_global_shared.data", 441_000_000),
        ("moss_tts_local_shared.data", 230_000_000),
        ("tokenizer.model", 471_000),
        ("tts_browser_onnx_meta.json", 4_500),
        ("browser_poc_manifest.json", 503_000),
    ]

    // `local_decoder.onnx`/`local_cached_step.onnx` ship in the same repo
    // but are unused dead weight — OpenMOSS's own Android reference never
    // calls them (only prefill/decode_step/local_fixed_sampled_frame are
    // used), so this prototype skips downloading them too.
    private static let codecFiles: [(name: String, bytes: Int64)] = [
        ("moss_audio_tokenizer_decode_full.onnx", 681_902),
        ("moss_audio_tokenizer_decode_shared.data", 44_198_912),
        ("codec_browser_onnx_meta.json", 17_036),
    ]

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("MossTtsNano", isDirectory: true)
    }

    static var ttsDirectory: URL { modelsDirectory.appendingPathComponent("tts", isDirectory: true) }
    static var codecDirectory: URL { modelsDirectory.appendingPathComponent("codec", isDirectory: true) }

    static func isDownloaded() -> Bool {
        let fm = FileManager.default
        let ttsReady = ttsFiles.allSatisfy { fm.fileExists(atPath: ttsDirectory.appendingPathComponent($0.name).path) }
        let codecReady = codecFiles.allSatisfy {
            fm.fileExists(atPath: codecDirectory.appendingPathComponent($0.name).path)
        }
        return ttsReady && codecReady
    }

    static func ensureModels(progressHandler: MossNanoProgressHandler?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ttsDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: codecDirectory, withIntermediateDirectories: true)

        let totalBytes = (ttsFiles + codecFiles).reduce(Int64(0)) { $0 + $1.bytes }
        var completedBytes: Int64 = 0

        func download(_ file: (name: String, bytes: Int64), from repo: String, into directory: URL) async throws {
            let destination = directory.appendingPathComponent(file.name)
            guard !fm.fileExists(atPath: destination.path) else {
                completedBytes += file.bytes
                progressHandler?(Double(completedBytes) / Double(totalBytes))
                return
            }
            guard let url = URL(string: "\(repo)/\(file.name)") else {
                throw MossNanoDownloadError.invalidURL(file.name)
            }
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw MossNanoDownloadError.badResponse(file.name)
            }
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tempURL, to: destination)
            completedBytes += file.bytes
            progressHandler?(min(Double(completedBytes) / Double(totalBytes), 0.999))
        }

        for file in ttsFiles {
            try await download(file, from: ttsRepo, into: ttsDirectory)
        }
        for file in codecFiles {
            try await download(file, from: codecRepo, into: codecDirectory)
        }
        progressHandler?(1.0)
    }
}
