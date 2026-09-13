import Foundation

/// Which ONNX Runtime execution provider a benchmark run used — the whole
/// point of this prototype (issue #25) is comparing these two.
enum MossNanoExecutionProvider {
    case cpu
    case coreMLANE
}

/// Per-stage wall-clock timing for one `MossNanoEngineService.synthesize`
/// call, broken out so a "CoreML+ANE helped prefill/decode but not the
/// per-frame local loop" result (a real, expected possibility — see the
/// plan doc's caveat about dynamic-shape graphs) is legible in the UI
/// rather than hidden inside one combined number.
struct MossNanoTimings {
    var prefillSeconds: Double = 0
    var decodeLoopSeconds: Double = 0
    var codecDecodeSeconds: Double = 0
    var totalSeconds: Double = 0
    var frameCount: Int = 0
    var audioDurationSeconds: Double = 0

    var realTimeFactor: Double {
        totalSeconds > 0 ? audioDurationSeconds / totalSeconds : 0
    }
}

struct MossNanoSynthesisResult {
    /// Mono, 32-bit float, range [-1, 1] — downmixed from the codec's real
    /// stereo output the same way the Android reference does, to keep this
    /// first pass simple.
    let pcm: [Float]
    let sampleRate: Int
    let timings: MossNanoTimings
}
