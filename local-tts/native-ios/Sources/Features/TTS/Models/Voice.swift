import Foundation

/// One voice's complete app-facing identity — everything the UI needs to
/// show it, in one place. Previously this lived as five separate sparse
/// dictionaries all keyed by the same code string (avatar names, taglines,
/// long descriptions, preview lines) plus two divergent prefix-parsing
/// implementations for the display name and flag, which meant adding a
/// language touched six files and made it easy to update one table and
/// forget the rest.
///
/// Everything optional is genuinely optional: a voice with no persona
/// research behind it (Pocket TTS, Japanese) carries `nil` rather than an
/// invented tagline.
struct Voice: Identifiable, Hashable, Sendable {
    /// The exact code the engine expects (`af_heart`, `zf_xiaobei`, `alba`).
    let code: String
    var tagline: String?
    var longDescription: String?
    /// Whether a real per-voice avatar image is bundled. The asset name is
    /// always `VoiceAvatar_<code>`, so only the flag needs storing.
    var hasAvatar: Bool = false
    /// The sentence this voice's bundled preview clip says — kept so the
    /// clips stay regenerable (see docs/adr/0009-bundled-voice-preview-clips.md).
    var previewLine: String?

    var id: String { code }

    /// `af_alloy` -> `Alloy`, `bill_boerst` -> `Bill Boerst`.
    var displayName: String { VoiceCode.displayName(for: code) }
    var flag: String { VoiceCode.flag(for: code) }
    var avatarAssetName: String? { hasAvatar ? "VoiceAvatar_\(code)" : nil }
}

/// Kokoro encodes locale and gender in the code's prefix (`af_` = American
/// female, `bm_` = British male, `zf_` = Mandarin female…). This is the one
/// place that knows that convention — the display name and the flag both
/// read from the same table, so adding a language can't leave one of them
/// behind the way it used to.
enum VoiceCode {
    private static let flagsByPrefix: [String: String] = [
        "af_": "🇺🇸", "am_": "🇺🇸",
        "bf_": "🇬🇧", "bm_": "🇬🇧",
        "zf_": "🇨🇳", "zm_": "🇨🇳",
        "jf_": "🇯🇵", "jm_": "🇯🇵",
    ]

    /// Pocket TTS voices are named after audiobook narrators with no locale
    /// in the name at all — they fall back to US English. Flag this
    /// assumption if it turns out wrong for a specific voice.
    private static let defaultFlag = "🇺🇸"

    static func flag(for code: String) -> String {
        for (prefix, flag) in flagsByPrefix where code.hasPrefix(prefix) {
            return flag
        }
        return defaultFlag
    }

    static func displayName(for code: String) -> String {
        var raw = Substring(code)
        for prefix in flagsByPrefix.keys where raw.hasPrefix(prefix) {
            raw.removeFirst(prefix.count)
            break
        }
        return
            raw
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
