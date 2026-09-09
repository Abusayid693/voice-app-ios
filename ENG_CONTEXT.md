# ENG_CONTEXT.md

Engineering context for this repo — what the app does, why it exists, and every non-obvious decision made so far. Read this at the start of a new session to understand the app without re-deriving everything from git history. **Keep this updated** whenever a feature, decision, or constraint changes — add to it, don't let it drift from reality.

For *how to organize new code*, see `CLAUDE.md` instead (architecture conventions + target file tree).

## What this app is

A standalone native iOS validation harness (`local-tts/native-ios/`, xcodegen-generated Xcode project — no Expo, no CocoaPods, deliberately separate from any other app) for testing two on-device TTS engines from [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)'s Swift SDK, on real hardware. Origin: a separate Expo app ("Voicenote") needs real, on-device TTS; wiring FluidAudio's Swift Package into that Expo/CocoaPods build is a real, risky change (`useFrameworks: dynamic`). This app exists to de-risk that decision first — confirm the engines actually work well, how big the downloads are, how fast synthesis is, and what the real constraints are — before touching the Expo app's working CPU TTS path at all. See `plan.md` at repo root for the original planning doc.

Signing: `project.yml` specifies Apple Development team `Q2F3H94YUP`, but the committed `.xcodeproj` currently has `V667L4VT6C` (Xcode changed this outside of any session, likely via automatic signing when opened directly in Xcode) — these are **out of sync**. Since `xcodegen generate` regenerates the `.xcodeproj` from `project.yml`, running it again will silently revert the team back to `Q2F3H94YUP`. Reconcile these (update `project.yml` to match whichever team actually works) before the next regenerate, or the signing will break again. Bundle id `com.rehanchoudhury.kokoroanetest`. iOS 17 deployment target, Swift 5.0.

## The two engines

### Kokoro-ANE (`KokoroAneManager`)
7-stage CoreML chain (Albert→PostAlbert→Alignment→Prosody→Noise→Vocoder→Tail). FluidAudio's own hosted HF repo only publishes one voice per language (`af_heart` English / `zf_001` Mandarin) — their docs call this a hard model-conversion constraint. **We confirmed that's not actually true at the architecture level**: every one of the 7 stages is voice-agnostic. `Albert`, `Alignment`, and `Tail` never touch voice data at all; `PostAlbert`/`Prosody` take `style_s` and `Noise`/`Vocoder` take `style_timbre` as plain runtime tensor inputs, not anything baked into compiled weights. This app ships a custom-bundled model set with every standard Kokoro-82M English voice working as a result — see "Custom Kokoro-ANE model bundle" below for how, and `ENG_CONTEXT.md`'s "voice-agnostic" finding is worth citing if filing the mismatch as a GitHub issue upstream.

Also hard-capped at **≤510 phonemes per call** (Albert's context window), no built-in chunker — the SDK has no autoregressive/streaming path for Kokoro at all (no `synthesizeStreaming()` on `KokoroAneManager`, and architecturally it can't have one: Albert→PostAlbert→Alignment decide the *entire* frame count up front, then the rest runs as one batched pass — there's no point where partial audio exists before the whole thing finishes, unlike PocketTTS's genuinely autoregressive frame-by-frame generation). The app works around both the length cap and the lack of streaming itself — see "Kokoro-ANE chunked, multi-track playback UI" below.

Uses `computeUnits: .default` (unmodified) — an OS-version-aware routing table baked into the SDK to avoid two known bugs (BNNS CPU segfault on iOS 26.4–26.5.x, fixed in 26.6+; GPU RNN JIT assert on macOS 26.5+/M5). Test device is iOS 26.6.1, past the fix line, so no workaround needed.

### Custom Kokoro-ANE model bundle (multi-voice support)

`local-tts/native-ios/CustomKokoroModel/` — **gitignored, ~93MB, fully regeneratable** — holds all 7 real FluidAudio stages (downloaded from `FluidInference/kokoro-82m-coreml`, byte-identical to what the SDK would normally fetch itself), `vocab.json`, and all 28 standard Kokoro-82M English voice `.bin` files (FluidAudio only publishes `af_heart.bin`; the rest are generated directly from the upstream PyTorch checkpoint — no CoreML involved). `DependencyContainer.kokoroManager` points `KokoroAneManager(directory:)` at this bundle instead of the default download location, so `ensureVoicePack` finds every voice already present locally and never touches the network.

**To regenerate the model files** (if the gitignored folder is missing, e.g. on a fresh clone):
```python
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="FluidInference/kokoro-82m-coreml",
    allow_patterns=[
        "ANE/KokoroAlbert.mlmodelc/*", "ANE/KokoroPostAlbert.mlmodelc/*",
        "ANE/KokoroAlignment.mlmodelc/*", "ANE/KokoroProsody.mlmodelc/*",
        "ANE/KokoroNoise_v2.mlmodelc/*", "ANE/KokoroVocoder.mlmodelc/*",
        "ANE/KokoroTail_v2.mlmodelc/*", "ANE/vocab.json",
    ],
)
```
Note the `_v2` suffixes on Noise/Tail — required exact filenames (`ModelNames.KokoroAne` in FluidAudio's source), and genuine bug fixes (Noise_v2: atan2 phase-correction removing audible high-frequency "sharpness"; Tail_v2: COLA-normalized iSTFT weights — the un-fixed version's raw output is exactly 1.5x too loud). `huggingface_hub` caches via symlinks into a shared blob store — copy with `cp -RL` (dereference) when moving into the project, or the bundled app will ship broken links.

For voice packs, extract directly from the upstream checkpoint (no `convert.py`/CoreML step at all — this is why voice-swapping works with zero model reconversion):
```python
import torch, numpy as np
from huggingface_hub import hf_hub_download
path = hf_hub_download(repo_id="hexgrad/Kokoro-82M", filename=f"voices/{name}.pt")
arr = torch.load(path, map_location="cpu", weights_only=True).numpy().astype(np.float32).reshape(510, 256)
open(f"{name}.bin", "wb").write(arr.tobytes())
```
The 28 English voice names are listed in `TTSViewModel.kokoroVoices`. Drop all of the above (7 `.mlmodelc` dirs + `vocab.json` + `*.bin` files) flat into `CustomKokoroModel/kokoro-82m-coreml/ANE/`.

**Two non-obvious integration details**, both required for this to actually run on-device:
- `project.yml` bundles `CustomKokoroModel/` with an explicit `type: folder` resource entry — this is what makes Xcode copy it as one atomic directory (preserving each `.mlmodelc`'s internal structure) instead of risking it getting flattened by the default source-scanning behavior.
- The installed `.app` bundle is **read-only** at runtime, but CoreML's ANE compilation step needs to *write* analytics/cache data into a model's folder the first time it loads (fails with "You don't have permission to save the file..." otherwise). `DependencyContainer` copies the bundled folder into `Application Support` (writable) once on first launch, and points `KokoroAneManager(directory:)` at that copy, not the bundle directly. Also: locate the bundled folder via `Bundle.main.bundleURL.appendingPathComponent(...)`, not `Bundle.main.url(forResource:withExtension:)` — the latter proved unreliable for this folder reference on-device.

### PocketTTS (`PocketTtsManager`)
Flow-matching LM + Mimi neural codec (autoregressive, per-80ms-frame generation), fundamentally heavier than Kokoro-ANE (~500MB+ vs ~166MB download) but **genuinely multi-voice**: 26 real published voices (`alba`, `anna`, `michael`, `george`, etc. — literary character names from `kyutai/pocket-tts`, mostly unrelated to Kokoro's `af_`/`am_`/`bf_`/`bm_` naming despite two name collisions with Kokoro voices, `michael`/`george`, which are *different* voices). Verified all 26 exist as real `.safetensors` files in `constants_bin/` on HF (not just docs) before adding them to the picker.

**Placement chosen deliberately: `.ane`, not the SDK's default `.gpu`.** The SDK's `.gpu` default is benchmarked/justified with Mac-specific numbers (M-series GPU vs ANE per-call latency); its own doc for `.ane` explicitly mentions "iOS placement" as a reason to use it. Since this app's whole purpose is validating the ANE path on iPhone, `.ane` was chosen over the library default. Consequence: `precision: .int8` has **no effect** under `.ane` placement (only `.gpu`'s FlowLM variant is quantizable) — download is ~503MB fp16, not the ~433MB int8+gpu figure that appeared in early testing before this was corrected.

Voice accent: **unconfirmed**. No dialect metadata found in docs or accessible source; upstream `kyutai/pocket-tts` model card is gated. Don't assume "American English" without checking on-device.

Playback: **streaming**, not buffered — `synthesizeStreaming()` yields 80ms `AudioFrame`s (chunked internally at ≤50 tokens/chunk, sentence→clause→word boundaries) fed incrementally into `AVAudioEngine`/`AVAudioPlayerNode` as they're generated, instead of assembling one WAV first. Exposes "time to first audio" and chunk-progress metrics in the UI.

**Known unresolved issue**: a small audible glitch/overlap at chunk boundaries within one long synthesis (the KV cache resets per chunk internally in the SDK). A fix was attempted (insert ~300ms silence buffer at each chunk boundary) and **explicitly reverted** at the user's request — do not re-attempt this exact approach without new direction; it works mechanically (verified building) but was undone before being kept. If revisiting, reconsider a smaller gap value and/or a crossfade instead of hard silence.

## Kokoro-ANE chunked, multi-track playback UI

Kokoro's 510-phoneme cap and lack of any streaming path (see above) meant long text either errored or you had to wait for the whole thing to synthesize before hearing anything. `Features/TTS/Models/KokoroTextChunker.swift` splits text on sentence boundaries (falling back to word boundaries for one very long sentence) at a conservative ~350-character budget (phoneme count isn't knowable without running G2P, so this is a character-count stand-in with headroom).

**Each "Generate" tap creates an independent track**, not one shared continuous stream — `KokoroGeneration` (`Features/TTS/Models/KokoroGeneration.swift`) holds one generation's sub-chunks, audio, and per-chunk state; `TTSViewModel.kokoroGenerations: [KokoroGeneration]` is append-only, like a playlist. `Features/TTS/Views/KokoroGenerationListView.swift` renders one row per track — its own play/pause/buffering button, a segmented bar for its own sub-chunk progress (blue = playing, light blue = generated, light grey = waiting, red = failed), and any error inline. Only one track plays at a time — selecting a different one stops whatever was active and starts the new one from its beginning, like switching songs; a track never auto-advances into a different track when it ends.

Generation itself is one persistent background worker (`ensureKokoroGenerationRunning()`) shared across all tracks — each iteration scans every track in creation order for its next `.waiting` chunk and synthesizes it, so a Generate tap while the worker is already running just adds more work to the same loop rather than needing a restart. A chunk that fails to synthesize is marked `.failed` (not left `.waiting` forever) with the error message attached to its track, and the worker moves on to the next chunk instead of dying — one bad chunk doesn't block or hang the rest of the queue.

Playback uses one `AVAudioPlayer` per chunk (not the `AVAudioEngine`/`AVAudioPlayerNode` PocketTTS uses) — `AVAudioPlayer.pause()`/`.play()` natively support pausing and resuming mid-chunk; a small `NSObject`-conforming delegate (`KokoroChunkPlaybackDelegate`) bridges `audioPlayerDidFinishPlaying` to advance to the next chunk within the active track.

**Bug already found and fixed once**: an earlier version conflated "start playback" with "regenerate" — tapping Play both decided whether to resume vs. restart *and* triggered generation, gated only on whether the chunk list was non-empty. That flag never got cleared after a run finished or when the text changed, so playing new text after finishing old text just replayed the stale, already-finished `AVAudioPlayer` instead of generating anything new. The Generate/Play split above is the fix — don't reintroduce a single combined "smart" button that tries to infer resume-vs-fresh from state; keep the two actions explicit and separate.

## Pronunciation control / text normalization

Kokoro-ANE: no SSML (`<phoneme>`/`<sub>`/`<say-as>`), no markdown `[word](/ipa/)` overrides — neither exists for `KokoroAneManager`. It does have a real custom-lexicon API (`setEnglishCustomLexicon([String: String])` / `setMandarinCustomLexicon(_:)`), not currently wired into the app. It already normalizes numbers/dates/currency internally before synthesis.

PocketTTS: no built-in number/date/currency normalization — added to the app. `TextNormalizer.shared.tnNormalizeSentence(_:)` (same native NeMo FST engine Kokoro uses internally, exposed here as a public API) runs on the input text in `runPocketTts()` before `synthesizeStreaming()`, so `"$5"` → "five dollars", `"12/12/2024"` → spoken date form, etc. Runs via `Task.detached` since it's a synchronous native call with no `await` — keeps a long input from blocking whichever actor the calling `Task` inherited.

## Download progress UI (both engines)

FluidAudio's own `ProgressHandler`/`DownloadProgress` only reports a fraction (`fractionCompleted: Double`, `phase: .listing/.downloading(completedFiles:totalFiles:)/.compiling`) — **no raw byte totals**. To show "X / Y MB," the app queries HuggingFace's public tree API directly (`https://huggingface.co/api/models/<repo>/tree/main/<path>?recursive=true`) and sums file sizes itself, filtered to just the files the chosen precision/placement config actually downloads (verified against `ModelNames.swift`'s `requiredModels(precision:placement:)` source, not guessed).

Progress-fraction weighting differs by download path (confirmed by reading `ModelHub.swift`): Kokoro's repo-download reserves `0.0–0.5` for download + `0.5–1.0` for a compile phase that never actually fires for these pre-compiled `.mlmodelc` bundles (so the app normalizes by dividing by `0.5`); PocketTTS's subdirectory-download path spans the full `0.0–1.0` (weight `1.0`, no normalization needed). Get this wrong and progress bars either stall at 50% or never reach 100%.

**"Already downloaded" detection is disk-based, not memory-based.** `manager.isAvailable()`-style flags only reflect what's loaded into the current process's RAM, which is always false on a fresh app launch even if the model files are sitting in `Application Support` (persisted, not auto-purged by iOS) from a previous run. The app instead tracks whether a real `.downloading`/`.listing` progress event actually fired (`didDownload`) — only then does it show the download UI or fetch the HF total-size estimate. This makes a warm-cache relaunch skip straight to "Loading models…" instead of showing a fake "Downloading model…".

## UI structure (as of this writing — see `CLAUDE.md` for target structure)

Restructuring to feature-first MVVM+Services (per `CLAUDE.md`'s target tree) is mostly done — commits 1 and 3 of the original 3-commit plan landed (commit 2, onboarding/`AppCoordinator`, was skipped for now). `TTSHomeView.swift` is now a thin View (`@ObservedObject var viewModel: TTSViewModel`, no `@State`, no FluidAudio/AVFoundation imports at all) bound to `TTSViewModel` (`@MainActor final class ...: ObservableObject`, owns all the `@Published` UI state and orchestration methods that used to live directly on the View). The actual FluidAudio/AVAudioEngine calls live in `KokoroEngineService`/`PocketEngineService`, constructed from the long-lived instances in `DependencyContainer` (created once in `KokoroAneTestApp`, passed down via plain constructor injection — no `.environmentObject`, since there's only one consumer today). `Core/Networking/HuggingFaceTreeSizeFetcher.swift` holds the generic HF tree-size helper both services' total-download-size display uses.

One screen: Engine picker (segmented, Kokoro-ANE/PocketTTS) → Voice section (real picker for both engines now — 28 voices for Kokoro backed by the custom model bundle, 26 for PocketTTS) → tappable text row → engine-specific controls → Status section (download progress, init timing, streaming metrics). For PocketTTS the controls are still the single "Download & Speak" button; for Kokoro-ANE they're the "Generate" button (under the text row, always creates a new track) plus `KokoroGenerationListView` (one row per track, see "Kokoro-ANE chunked, multi-track playback UI" above). Tapping the text row opens `TextEntrySheet`, a `.fullScreenCover` (full-screen slide-up modal) with a large `TextEditor`, a "Listen" button (waveform icon, top-left — for Kokoro this chains generate-then-play as one tap, for PocketTTS it's the same single action as the main screen) and a close "X" (top-right).

**Not yet done**: `AppCoordinator` + onboarding flow (commit 2) — the app currently opens straight to `TTSHomeView`, no gate in front of it. Full original plan at `/Users/rehanchoudhury/.claude/plans/can-we-strcure-this-polished-book.md` if picking this back up.

## Open items / things a future session should know before touching this

- Signing team drift between `project.yml` and the committed `.xcodeproj` keeps recurring — `xcodegen generate` reverts the team back to whatever `project.yml` says (`Q2F3H94YUP`) every time, even after Xcode's automatic signing picks a different working team (`V667L4VT6C` was seen once). Reconcile `project.yml` to the actually-working team, or expect signing to break after every regenerate.
- Kokoro-ANE's 510-phoneme cap is now worked around via app-level chunking (`KokoroTextChunker`) — no longer an open gap, see "Kokoro-ANE chunked, multi-track playback UI" above.
- `CustomKokoroModel/` is gitignored — if it's missing (fresh clone), regenerate it via the recipe in "Custom Kokoro-ANE model bundle" above before Kokoro-ANE will work with anything but a network-downloaded `af_heart`.
- PocketTTS chunk-boundary glitch is unresolved (see above — a fix was tried and reverted).
- PocketTTS voice accent (American vs. other English) is unverified — check on-device before claiming anything about it.
- MVVM+Services restructuring: commits 1 and 3 done, commit 2 (onboarding/`AppCoordinator`) not started.
- The full MVVM+Services extraction (commit 3) was verified only via `xcodebuild` (simulator build succeeds, no logic changed beyond moving code) — it has **not** been manually regression-tested on-device yet. Run through both engines' complete flows (cold download, warm relaunch, synth+playback) before trusting this is bug-free.
