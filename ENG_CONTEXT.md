# ENG_CONTEXT.md

Engineering context for this repo — what the app does, why it exists, and every non-obvious decision made so far. Read this at the start of a new session to understand the app without re-deriving everything from git history. **Keep this updated** whenever a feature, decision, or constraint changes — add to it, don't let it drift from reality.

For *how to organize new code*, see `CLAUDE.md` instead (architecture conventions + target file tree).

## What this app is

A standalone native iOS validation harness (`local-tts/native-ios/`, xcodegen-generated Xcode project — no Expo, no CocoaPods, deliberately separate from any other app) for testing two on-device TTS engines from [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)'s Swift SDK, on real hardware. Origin: a separate Expo app ("Voicenote") needs real, on-device TTS; wiring FluidAudio's Swift Package into that Expo/CocoaPods build is a real, risky change (`useFrameworks: dynamic`). This app exists to de-risk that decision first — confirm the engines actually work well, how big the downloads are, how fast synthesis is, and what the real constraints are — before touching the Expo app's working CPU TTS path at all. See `plan.md` at repo root for the original planning doc.

Signing: `project.yml` specifies Apple Development team `Q2F3H94YUP`, but the committed `.xcodeproj` currently has `V667L4VT6C` (Xcode changed this outside of any session, likely via automatic signing when opened directly in Xcode) — these are **out of sync**. Since `xcodegen generate` regenerates the `.xcodeproj` from `project.yml`, running it again will silently revert the team back to `Q2F3H94YUP`. Reconcile these (update `project.yml` to match whichever team actually works) before the next regenerate, or the signing will break again. Bundle id `com.rehanchoudhury.kokoroanetest`. iOS 17 deployment target, Swift 5.0.

## The two engines

### Kokoro-ANE (`KokoroAneManager`)
7-stage CoreML chain (ALBERT→PostAlbert→Alignment→Prosody→Noise→Vocoder→Tail), 4 stages ANE-resident, 3 GPU. **Hard-locked to exactly one voice per language** — `af_heart` (English), `zf_001` (Mandarin) — confirmed via the SDK's own docs: *"This single-voice-per-variant constraint is intrinsic to the upstream conversion — adding voices requires re-converting PostAlbert/Prosody/Noise/Vocoder against the new style embeddings."* This is **not** a missing-download gap (checked: no allowlist/validation anywhere in the download code — `ensureVoicePack` will happily try to fetch any voice name, it just 404s because the `.bin` file for anything but `af_heart`/`zf_001` doesn't exist on HuggingFace). So the app's UI shows a fixed `af_heart` label, not a picker — there's genuinely nothing else to offer.

Also hard-capped at **≤510 phonemes per call** (ALBERT context window), no built-in chunker. **Not currently guarded in the app** — a long paragraph fed to Kokoro-ANE will error or truncate rather than being caught gracefully. Known gap, not yet fixed.

Uses `computeUnits: .default` (unmodified) — this is itself an OS-version-aware routing table baked into the SDK to avoid two known bugs (BNNS CPU segfault on iOS 26.4–26.5.x, fixed in 26.6+; GPU RNN JIT assert on macOS 26.5+/M5). Test device is iOS 26.6.1, past the fix line, so no workaround needed.

Playback: one-shot buffered `synthesize()` → `Data` (WAV) → `AVAudioPlayer`.

### PocketTTS (`PocketTtsManager`)
Flow-matching LM + Mimi neural codec (autoregressive, per-80ms-frame generation), fundamentally heavier than Kokoro-ANE (~500MB+ vs ~166MB download) but **genuinely multi-voice**: 26 real published voices (`alba`, `anna`, `michael`, `george`, etc. — literary character names from `kyutai/pocket-tts`, mostly unrelated to Kokoro's `af_`/`am_`/`bf_`/`bm_` naming despite two name collisions with Kokoro voices, `michael`/`george`, which are *different* voices). Verified all 26 exist as real `.safetensors` files in `constants_bin/` on HF (not just docs) before adding them to the picker.

**Placement chosen deliberately: `.ane`, not the SDK's default `.gpu`.** The SDK's `.gpu` default is benchmarked/justified with Mac-specific numbers (M-series GPU vs ANE per-call latency); its own doc for `.ane` explicitly mentions "iOS placement" as a reason to use it. Since this app's whole purpose is validating the ANE path on iPhone, `.ane` was chosen over the library default. Consequence: `precision: .int8` has **no effect** under `.ane` placement (only `.gpu`'s FlowLM variant is quantizable) — download is ~503MB fp16, not the ~433MB int8+gpu figure that appeared in early testing before this was corrected.

Voice accent: **unconfirmed**. No dialect metadata found in docs or accessible source; upstream `kyutai/pocket-tts` model card is gated. Don't assume "American English" without checking on-device.

Playback: **streaming**, not buffered — `synthesizeStreaming()` yields 80ms `AudioFrame`s (chunked internally at ≤50 tokens/chunk, sentence→clause→word boundaries) fed incrementally into `AVAudioEngine`/`AVAudioPlayerNode` as they're generated, instead of assembling one WAV first. Exposes "time to first audio" and chunk-progress metrics in the UI.

**Known unresolved issue**: a small audible glitch/overlap at chunk boundaries within one long synthesis (the KV cache resets per chunk internally in the SDK). A fix was attempted (insert ~300ms silence buffer at each chunk boundary) and **explicitly reverted** at the user's request — do not re-attempt this exact approach without new direction; it works mechanically (verified building) but was undone before being kept. If revisiting, reconsider a smaller gap value and/or a crossfade instead of hard silence.

## Pronunciation control / text normalization

Kokoro-ANE: no SSML (`<phoneme>`/`<sub>`/`<say-as>`), no markdown `[word](/ipa/)` overrides — neither exists for `KokoroAneManager`. It does have a real custom-lexicon API (`setEnglishCustomLexicon([String: String])` / `setMandarinCustomLexicon(_:)`), not currently wired into the app. It already normalizes numbers/dates/currency internally before synthesis.

PocketTTS: no built-in number/date/currency normalization — added to the app. `TextNormalizer.shared.tnNormalizeSentence(_:)` (same native NeMo FST engine Kokoro uses internally, exposed here as a public API) runs on the input text in `runPocketTts()` before `synthesizeStreaming()`, so `"$5"` → "five dollars", `"12/12/2024"` → spoken date form, etc. Runs via `Task.detached` since it's a synchronous native call with no `await` — keeps a long input from blocking whichever actor the calling `Task` inherited.

## Download progress UI (both engines)

FluidAudio's own `ProgressHandler`/`DownloadProgress` only reports a fraction (`fractionCompleted: Double`, `phase: .listing/.downloading(completedFiles:totalFiles:)/.compiling`) — **no raw byte totals**. To show "X / Y MB," the app queries HuggingFace's public tree API directly (`https://huggingface.co/api/models/<repo>/tree/main/<path>?recursive=true`) and sums file sizes itself, filtered to just the files the chosen precision/placement config actually downloads (verified against `ModelNames.swift`'s `requiredModels(precision:placement:)` source, not guessed).

Progress-fraction weighting differs by download path (confirmed by reading `ModelHub.swift`): Kokoro's repo-download reserves `0.0–0.5` for download + `0.5–1.0` for a compile phase that never actually fires for these pre-compiled `.mlmodelc` bundles (so the app normalizes by dividing by `0.5`); PocketTTS's subdirectory-download path spans the full `0.0–1.0` (weight `1.0`, no normalization needed). Get this wrong and progress bars either stall at 50% or never reach 100%.

**"Already downloaded" detection is disk-based, not memory-based.** `manager.isAvailable()`-style flags only reflect what's loaded into the current process's RAM, which is always false on a fresh app launch even if the model files are sitting in `Application Support` (persisted, not auto-purged by iOS) from a previous run. The app instead tracks whether a real `.downloading`/`.listing` progress event actually fired (`didDownload`) — only then does it show the download UI or fetch the HF total-size estimate. This makes a warm-cache relaunch skip straight to "Loading models…" instead of showing a fake "Downloading model…".

## UI structure (as of this writing — see `CLAUDE.md` for target structure)

Restructuring to feature-first MVVM+Services (per `CLAUDE.md`'s target tree) is in progress, staged as three commits to isolate risk. **Commit 1/3 (pure file relocation, zero logic change) is done**: `Sources/` is now `App/`, `Features/TTS/{Views,Models}`, `Resources/` — `TTSHomeView.swift` (renamed from `ContentView.swift`), `TextEntrySheet.swift`, and `Engine.swift` live under `Features/TTS/`. The View still owns all `@State` and business logic directly (no ViewModel/Service layer yet — that's commit 3). One screen: Engine picker (segmented, Kokoro-ANE/PocketTTS) → Voice section (fixed label for Kokoro, real picker for PocketTTS) → tappable text row → "Download & Speak" → Status section (download progress, init timing, streaming metrics). Tapping the text row opens `TextEntrySheet`, a `.fullScreenCover` (full-screen slide-up modal) with a large `TextEditor`, a "Listen" button (waveform icon, top-left, triggers the same run flow) and a close "X" (top-right).

**Commits 2 and 3 not yet done**: (2) add `AppCoordinator` + a placeholder onboarding flow gating the existing screen; (3) extract the business logic into `TTSViewModel` + `KokoroEngineService`/`PocketEngineService` + `DependencyContainer` — flagged as the highest-risk step since it touches the working streaming/download code paths (`AVAudioEngine` lifecycle, actor-isolated `Task { @MainActor in }` closures) and needs full regression testing on both engines afterward. Full plan at `/Users/rehanchoudhury/.claude/plans/can-we-strcure-this-polished-book.md`.

## Open items / things a future session should know before touching this

- Signing team drift between `project.yml` and the committed `.xcodeproj` — see "What this app is" above. Fix before running `xcodegen generate` again.
- Kokoro-ANE has no phoneme-length guard (510 cap) — long text will error, not gracefully degrade.
- PocketTTS chunk-boundary glitch is unresolved (see above — a fix was tried and reverted).
- PocketTTS voice accent (American vs. other English) is unverified — check on-device before claiming anything about it.
- MVVM+Services restructuring: commit 1/3 done, commits 2-3 not started (see "UI structure" above).
