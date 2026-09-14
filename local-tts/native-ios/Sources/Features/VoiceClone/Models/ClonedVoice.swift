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
    // Which Pocket TTS language pack this voice was cloned with — needed
    // to re-select the right manager/service when generating with it
    // later (see TTSViewModel.pocketLanguage). Defaults to `.english` on
    // decode for voices saved before multi-language support existed, since
    // English was the only option then.
    var language: PocketLanguage = .english

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

    init(id: UUID, name: String, createdAt: Date, language: PocketLanguage = .english) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.language = language
    }

    // Custom decoding: `language` didn't exist before multi-language
    // support, so voices saved by an older build have no such key in
    // their persisted JSON. The auto-synthesized decoder would throw
    // `keyNotFound` on that — verified directly, not assumed — silently
    // wiping every existing user's cloned voices via loadMetadata()'s
    // `try?`. `decodeIfPresent` falls back to `.english` instead, since
    // English was the only option when those voices were made.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        language = try container.decodeIfPresent(PocketLanguage.self, forKey: .language) ?? .english
    }
}
