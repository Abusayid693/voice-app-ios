import Foundation

/// Sums file sizes from HuggingFace's public tree API for a given repo
/// path — used by `TTSViewModel`'s "total download size" display, since
/// FluidAudio's own progress callback reports a fraction, not byte totals.
enum HuggingFaceTreeSizeFetcher {
    private struct Entry: Decodable {
        let type: String
        let size: Int64?
        let path: String
    }

    static func fetchTotalBytes(url: String, matching: @escaping (String) -> Bool) async -> Int64? {
        guard let url = URL(string: url) else { return nil }
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
