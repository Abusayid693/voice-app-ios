import Foundation

/// Human-readable name for a raw voice code, for call sites that only have
/// the code and no `Voice` (Library's saved generations, for one). Voices
/// from the catalog expose the same thing as `Voice.displayName`.
enum VoiceDisplayName {
    static func forCode(_ code: String) -> String {
        VoiceCode.displayName(for: code)
    }
}
