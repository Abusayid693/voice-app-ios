import Foundation

enum FileNameFormatter {
    static func displayTitle(from fileName: String) -> String {
        let decoded = fileName.removingPercentEncoding ?? fileName
        let withoutExtension = (decoded as NSString).deletingPathExtension
        let normalized = withoutExtension
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !normalized.isEmpty else { return "Untitled PDF" }
        return normalized.localizedCapitalized
    }
}
