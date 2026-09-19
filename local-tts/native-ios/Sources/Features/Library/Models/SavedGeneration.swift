import Foundation

/// A past "Generate" tap's original text, split into chapters, plus what
/// voice it used — saved so the Library tab (and Home's Projects row) has
/// something real to list. Persisted via UserDefaults+JSON (same style as
/// ClonedVoice). Generating no longer synthesizes audio itself — that only
/// happens when the user taps Generate on an individual chapter in
/// ChaptersListView, which saves one merged WAV per generated chapter (see
/// `chapterAudioFileURL`/`chapterSidecarFileURL`) rather than the flat
/// per-chunk files this used to write. Pocket TTS and Supertonic-3 chapters
/// only ever stream (per-chapter Generate is Kokoro-only), so they never
/// have saved audio.
struct SavedGeneration: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let engine: Engine
    let voiceName: String
    let createdAt: Date
    let chapters: [Chapter]

    init(id: UUID, text: String, engine: Engine, voiceName: String, createdAt: Date, chapters: [Chapter]) {
        self.id = id
        self.text = text
        self.engine = engine
        self.voiceName = voiceName
        self.createdAt = createdAt
        self.chapters = chapters
    }

    // Custom decoding: `chapters` didn't exist before this feature, so
    // entries saved by an older build have no such key in their persisted
    // JSON. The auto-synthesized decoder would throw `keyNotFound` on
    // that, silently wiping every existing user's saved generations via
    // LibraryViewModel.load()'s `try?` (same risk ClonedVoice's `language`
    // field hit — see that file). `decodeIfPresent` falls back to a
    // single chapter holding the whole saved `text`, matching how these
    // entries actually behaved before chapters existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        engine = try container.decode(Engine.self, forKey: .engine)
        voiceName = try container.decode(String.self, forKey: .voiceName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        if let decoded = try container.decodeIfPresent([Chapter].self, forKey: .chapters) {
            chapters = decoded
        } else {
            chapters = [Chapter(index: 0, title: "Chapter 1", text: text)]
        }
    }

    /// Shared by LibraryViewModel/ChapterAudioStore (writes/deletes) and
    /// whoever plays a saved chapter back — a single source of truth for
    /// where a project's chapter audio lives, same convention as
    /// `ClonedVoice.fileURL`. Purely computed from `id`, so no new Codable
    /// field is needed for it. Not `private` — Settings' StorageView reads
    /// this directly to size all saved chapter audio, same as it does for
    /// `ClonedVoice.directory`.
    static let baseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("SavedGenerations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    var audioDirectory: URL {
        Self.baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// The merged, single-file WAV for a generated chapter — see
    /// ChapterSynthesisService, which builds it from that chapter's
    /// individual synthesis chunks via WavConcatenator.
    func chapterAudioFileURL(index: Int) -> URL {
        audioDirectory.appendingPathComponent("chapter_\(index).wav")
    }

    /// The sidecar manifest (chunk texts + cumulative start times) that
    /// makes read-along highlighting and tap-to-seek work against the
    /// single merged file above, without re-deriving chunk boundaries by
    /// re-running the chunker (the old, fragile `playPersistedAudio`
    /// approach this replaces).
    func chapterSidecarFileURL(index: Int) -> URL {
        audioDirectory.appendingPathComponent("chapter_\(index).json")
    }

    func hasGeneratedAudio(chapterIndex: Int) -> Bool {
        FileManager.default.fileExists(atPath: chapterAudioFileURL(index: chapterIndex).path)
    }
}
