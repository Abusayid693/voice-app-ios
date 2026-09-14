import Foundation

/// A past "Generate" tap's original text + what voice it used — saved so
/// the Library tab has something real to list. Persisted via
/// UserDefaults+JSON (same style as ClonedVoice). Kokoro generations also
/// get their audio persisted alongside this record (see
/// LibraryViewModel.attachAudio) once every chunk finishes, one file per
/// chunk — not one combined file — so replay reconstructs the exact same
/// `chunkTexts`/`chunkAudio` structure a live generation uses, and
/// chunk-level read-along highlighting works identically either way.
/// Pocket TTS never gets audio saved (it has no accumulated buffer to
/// save, only streamed frames — see issue #11), so a Pocket entry can
/// only ever be viewed as text. Supertonic-3 (issue #27) is saved the same
/// way — text only, no audio — even though it does produce one complete
/// buffer like Kokoro: the SDK chunks its text internally with no
/// app-visible boundaries, so it can't reuse Kokoro's chunk-reconstruction
/// replay path, and has no read-along screen of its own.
struct SavedGeneration: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let engine: Engine
    let voiceName: String
    let createdAt: Date

    /// Shared by LibraryViewModel (writes/deletes) and whoever plays a
    /// saved entry back — a single source of truth for where a completed
    /// generation's audio lives, same convention as `ClonedVoice.fileURL`.
    /// Purely computed from `id`, so no new Codable field was needed —
    /// existing persisted entries (from before audio saving existed) just
    /// resolve to a directory with nothing in it yet.
    private static let baseDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("SavedGenerations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    var audioDirectory: URL {
        Self.baseDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func chunkAudioFileURL(index: Int) -> URL {
        audioDirectory.appendingPathComponent("chunk_\(index).wav")
    }

    /// Whether this entry's audio has actually been saved yet — false for
    /// Pocket entries (never saved), and for Kokoro entries where
    /// generation never finished (app closed mid-generation, a chunk
    /// failed) or that predate this feature.
    var hasSavedAudio: Bool {
        FileManager.default.fileExists(atPath: chunkAudioFileURL(index: 0).path)
    }
}
