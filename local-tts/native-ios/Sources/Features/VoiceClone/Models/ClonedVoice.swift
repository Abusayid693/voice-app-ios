import Foundation

/// Metadata for a user-cloned voice. The actual FluidAudio
/// `PocketTtsVoiceData` binary lives in a separate file at `fileURL`,
/// named by `id` — this struct is just the small, Codable, list-friendly
/// record of it (persisted via UserDefaults+JSON — see
/// VoiceCloneViewModel).
struct ClonedVoice: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date

    /// Shared by both VoiceCloneViewModel (writes/deletes) and
    /// TTSViewModel (reads, to actually generate with a cloned voice) —
    /// a single source of truth for where these binaries live so neither
    /// has to duplicate the path convention.
    static let directory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("ClonedVoices", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    var fileURL: URL {
        Self.directory.appendingPathComponent("\(id).bin")
    }
}
