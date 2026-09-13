import Foundation
import SentencePiece

/// Thin wrapper around `liuliu/swift-sentencepiece`'s base encode over
/// MOSS-TTS-Nano's raw `tokenizer.model`. Verified against the base
/// checkpoint's own `tokenization_moss_tts_nano.py`: it's a plain
/// SentencePiece wrapper with no special-token wrapping of its own — every
/// one of MOSS's structural tokens (audio start/end, user/assistant slot,
/// padding) is a raw numeric ID from the manifest, spliced in during
/// row-building in `MossNanoEngineService`, not produced by this
/// tokenizer.
///
/// This package (not `jkrukowski/swift-sentencepiece`, tried first) is the
/// one actually wired up — see the comment in `project.yml` next to the
/// `SentencePiece` package entry for why: the other package ships a
/// prebuilt `.xcframework` that collides with FluidAudio's own bundled one
/// at build time, while this one compiles SentencePiece from C++ source.
struct MossNanoTokenizer {
    private let tokenizer: SentencePiece

    init(modelPath: String) {
        tokenizer = SentencePiece(file: modelPath)
    }

    func encode(_ text: String) -> [Int] {
        tokenizer.encode(text).map { Int($0.id) }
    }
}
