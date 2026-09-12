import Foundation

/// Shared "open a saved Kokoro generation" logic for the Library tab and
/// Import's Projects section — tries the persisted per-chunk audio first
/// (so chunk-level read-along highlighting works identically to a live
/// generation), falling back to regenerating live if no audio was ever
/// saved (an older entry, or one whose generation never finished), and
/// backfilling it once that regeneration completes so the next open plays
/// straight from disk. Callers should only call this for Kokoro entries —
/// Pocket has no saved audio and no read-along screen yet.
///
/// `@MainActor` to match `TTSViewModel`/`LibraryViewModel`, both of which
/// are main-actor-isolated classes this only ever gets called from SwiftUI
/// view code (already on the main actor).
@MainActor
enum LibraryPlayback {
    @discardableResult
    static func open(
        _ generation: SavedGeneration, ttsViewModel: TTSViewModel, libraryViewModel: LibraryViewModel
    ) -> KokoroGeneration.ID? {
        if let chunkAudio = libraryViewModel.loadChunkAudio(for: generation),
            let newID = ttsViewModel.playPersistedAudio(text: generation.text, chunkAudio: chunkAudio)
        {
            return newID
        }

        return ttsViewModel.playFromSavedGeneration(
            text: generation.text, voice: generation.voiceName,
            onFullyGenerated: { chunkAudio in
                libraryViewModel.attachAudio(chunkAudio, to: generation.id)
            })
    }
}
