import Foundation

/// Turns a raw voice code ("af_heart", "bill_boerst") into a human-readable
/// display name ("Heart", "Bill Boerst") — shared by Import's trending
/// voice tiles and the Library tab's generation rows, so a raw voice code
/// never leaks into user-facing text in either place.
enum VoiceDisplayName {
    private static let kokoroPrefixes = ["af_", "am_", "bf_", "bm_", "zf_", "zm_", "jf_", "jm_"]

    static func forCode(_ code: String) -> String {
        var raw = Substring(code)
        for prefix in kokoroPrefixes where raw.hasPrefix(prefix) {
            raw.removeFirst(prefix.count)
            break
        }
        return raw
            .split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
