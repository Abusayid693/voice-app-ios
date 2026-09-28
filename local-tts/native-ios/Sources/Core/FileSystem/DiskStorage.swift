import Foundation

/// On-disk locations this app reads to compute real storage usage for the
/// Settings > Storage/Voice Packs pages — not used for reading/writing pack
/// files themselves (DependencyContainer/FluidAudio own that).
enum DiskStorage {
    /// Recursive total size in bytes of everything under `url`, or 0 if it
    /// doesn't exist or can't be enumerated.
    static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard
            let enumerator = fm.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
