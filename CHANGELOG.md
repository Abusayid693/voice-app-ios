# Changelog

All notable changes to this project are documented here. Format loosely follows [Keep a Changelog](https://keepachangelog.com/); version is read from `local-tts/native-ios/project.yml`'s `CFBundleShortVersionString`.

## [Unreleased]

### Added
- **EPUB import** — Add Books and Upload File now accept `.epub` alongside `.pdf`, landing on the same shelf with a cover, spine, and durable resumable job as a PDF import. Pages are chapter-wise: a new page always starts at a spine document boundary and at every table-of-contents anchor, so a book that puts several chapters (or its whole text) in one XHTML file still pages as if each chapter had its own file, and two chapters never share a page. The Pages picker shows top-level chapters as collapsible headers — collapsed by default, tap to reveal that chapter's pages, the current chapter auto-expanded — for an EPUB; a PDF keeps its plain flat list. No ligature loss, drop-cap misreading, running heads, or scrambled decorative titles, since EPUB's markup carries real structure (`<h1>`–`<h6>`, `<p>`, `<blockquote>`, `<li>`) instead of PDF's geometry having to be reverse-engineered into it — see `docs/adr/0014-epub-import.md`. No third-party dependency: ZIP via `Compression.framework`, XHTML via `XMLParser`. Cover art is read from the EPUB's own declared cover image rather than rendered. No table support and no inline images (cover only) in this first pass
- **Imported PDFs keep their own typography** — the reader reproduces each paragraph's size relative to the document's own body text (captions and footnotes render smaller, headings larger), its real weight on a six-step scale rather than a bold/not-bold flag, and its serif/sans/mono class where that contrasts with the document's body face. Weight is read primarily off the face *name*, since embedded PDF fonts routinely ship no weight trait at all. Styling is recorded per source line and applied per word, keyed by character offset — a heading merged into one synthesis chunk with the paragraph after it no longer loses its styling, and its weight no longer bleeds onto the lines below. The reader's own font choice still governs ordinary body text. Affects newly imported PDFs; existing books keep the styling they were imported with
- **One player, two views** — read-along and the audio player are now two surfaces of a single screen over a single playback engine, switched by a toolbar icon, the way Speechify and ElevenReader work. Switching never interrupts playback: both are branches of one view over one player, so the audio keeps going at the same position. Leaving the reader no longer stops playback either — it hands off to the floating mini player. `ChapterAudioPlayer` was deleted and its read-along surface (word timings, seek, play-from-word) folded into `BookAudioPlayer`'s gapless engine, which brings the audio session, lock-screen transport and background survival read-along never had. Playback position now comes from the audio node's own render clock rather than a wall clock, which also fixes the highlight sliding ahead of the voice after a synthesis stall. See `docs/adr/0013-unified-player.md` (supersedes 0012)
- Music mode (`Features/Listening/`): continuous, lock-screen-surviving playback of a whole book, separate from read-along — cover art, a whole-book progress bar, a draggable per-page scrubber, and lock-screen/Control Centre transport (play/pause, ±15s, scrub, next/previous page). Reached from the Book Shelf detail modal's headphones button beside "Read this"; minimises to an Apple-Music-style floating mini player above the Explore/Add Books bar. Shares reading position and Reading Stats with the reader, and the two are mutually exclusive — starting one pauses (never stops) the other — but are otherwise fully independent engines; see `docs/adr/0012-two-playback-engines.md`

### Fixed
- Words lost their `fi`/`ff`/`fl` letters in some imported PDFs — "fight" read as "ght", "officially" as "o cially" — because those fonts substitute a single ligature glyph and omit the mapping back to characters, so the letters are absent from the file's text layer and every PDF reader loses them the same way. Damaged books are now detected (a book with essentially no `fi`/`ff`/`fl` pairs at all) and repaired against the system dictionary at import. Books that extract cleanly are never touched. This fixes the spoken audio as much as the text, since the engine was being handed the broken words
- Running heads carrying a *chapter* title were read aloud at the top of every page of that chapter. Recurrence is now counted rather than measured as a share of the document, so a head covering one chapter is caught; a size check and the header/footer band keep a chapter's own opening title
- Headings, contents entries and list items were read aloud running straight into the paragraph that followed them, because the text handed to the engine collapsed paragraph breaks away entirely and Kokoro takes its prosody from punctuation alone. Each paragraph inside a chunk is now closed off as its own sentence. Applies to books already imported, since nothing about it is persisted

### Changed
- Generate no longer synthesizes audio directly — it saves the text split into chapters (≤2000 words each), and a new chapters list lets each chapter be streamed on demand (any engine) or, for Kokoro, generated and saved as one real file with a proper music-player screen (artwork, scrubber, real elapsed/duration) — see `docs/adr/0010-chapters-and-per-chapter-saved-audio.md` (supersedes ADR 4)
- Library and Home's Projects row now open the same chapters list for every engine, not just Kokoro
- "Initializing model…" cold-start notice while an engine warms up for the first time
- Home's top action row is now two swipeable tabs ("Listen to text" / "Make audio")

### Removed
- The old Kokoro multi-track playlist system (`KokoroGeneration`, the chunk-scanning background worker, `ReadAlongPlayerView`, `KokoroGenerationListView`) and the retired `TTSHomeView`/`TextEntrySheet` debug screen, replaced by the chapters flow above
- Pocket TTS and voice cloning removed entirely — Kokoro-ANE is the only engine. `Engine.pocketTts` is gone with no legacy decode path, so any saved project still naming it will fail to decode
- The "Generate" feature — persisting a page's audio as one merged WAV + timing manifest for real scrubbing/replay. Streaming (synthesize-and-play, chunk by chunk) is now the only playback path; nothing is written to disk. Removed with it: `ChapterGenerationStore`, `ChapterAudioStore`/`PageAudioStore`, `ChapterAudioManifest`, `WavConcatenator`, the reader header's Generate/progress/cancel control, and `SavedGeneration`'s generated-audio file paths. `updateVoice` no longer deletes a per-project audio directory (there's nothing to delete), and Settings > Storage no longer shows a "Generated chapters" row. See `docs/adr/0010-chapters-and-per-chapter-saved-audio.md`, updated to note the supersession

## [0.1.0] - 2026-09-12

### Added
- Two on-device TTS engines: Kokoro-ANE (28 custom-bundled voices, chunked multi-track playback for long text) and PocketTTS (26 voices, streaming synthesis, voice cloning)
- Import tab: Trending voices (playable previews, swipeable per-voice card sheet), What's trending (live Gutendex feed), Write text flow, Setup flow for both voice packs
- Read-along player for Kokoro generations — chunk-level highlighting, auto-scroll with manual override
- Library: saved generations with persisted per-chunk audio — replay without regenerating
- Voice cloning (PocketTTS only): record or import a sample, clone, generate with it
- Settings: Voice Packs / Storage (real on-disk sizes) / About
- Voice cover art: real AI-generated avatars for select voices, deterministic orb fallback for the rest
- Audio-reactive blob-shaped cover art deformation on the voice preview sheet
- Lucide icon set across the app

### Known limitations
- Onboarding/`AppCoordinator` not built — app opens straight to Import
- PocketTTS: chunk-boundary audio glitch unresolved; voice accent unconfirmed; no bundled previews yet
- Voice cloning not regression-tested on-device since it was built
- Most Kokoro voices and all Pocket voices still show an orb rather than a real avatar

See `docs/adr/` for the reasoning behind these and other non-obvious decisions.
