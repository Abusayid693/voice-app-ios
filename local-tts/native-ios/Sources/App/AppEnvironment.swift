import SwiftUI

/// The app's long-lived observable objects, bundled so intermediate views
/// stop forwarding ones they never read (`RootTabView` used to take six
/// parameters purely to hand them to its tab roots).
///
/// Deliberately a plain `struct`, **not** an `ObservableObject`, and
/// delivered via `@Environment(\.app)` rather than `@EnvironmentObject`:
/// reading it subscribes a view to nothing at all. That matters here — this
/// app's re-render discipline (see CLAUDE.md: "object granularity *is*
/// re-render granularity") depends on a view observing only the objects it
/// actually reads, and `@EnvironmentObject` has no equivalent of the plain
/// `let` escape hatch that discipline relies on.
///
/// So: a view that needs to *observe* an object still takes that one object
/// as an explicit `@ObservedObject` parameter from its parent — the
/// subscription stays narrow and visible. This container only removes the
/// pass-through burden for objects a view merely hands onward.
struct AppEnvironment {
    let tts: TTSViewModel
    let voiceClone: VoiceCloneViewModel
    let library: LibraryViewModel
    let previewPlayer: VoicePreviewPlayer
    let chapterPlayer: ChapterAudioPlayer
    let generationStore: ChapterGenerationStore
}

extension AppEnvironment {
    /// A throwaway object graph for `#Preview` only — previews render a
    /// real view hierarchy, so they need the same objects injected that
    /// `KokoroAneTestApp` injects at launch.
    @MainActor
    static func preview() -> AppEnvironment {
        let dependencies = DependencyContainer()
        let tts = TTSViewModel(dependencies: dependencies)
        let synthesis = ChapterSynthesisService(kokoroServices: tts.kokoroServices)
        return AppEnvironment(
            tts: tts, voiceClone: VoiceCloneViewModel(dependencies: dependencies),
            library: LibraryViewModel(), previewPlayer: VoicePreviewPlayer(),
            chapterPlayer: ChapterAudioPlayer(synthesisService: synthesis),
            generationStore: ChapterGenerationStore(synthesisService: synthesis))
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    // No meaningful default — every object in here needs a real
    // DependencyContainer. Injected once in KokoroAneTestApp; a crash here
    // means a view hierarchy (or a #Preview) was built without it.
    static var defaultValue: AppEnvironment {
        fatalError("AppEnvironment was never injected — call .environment(\\.app, …) at the root")
    }
}

extension EnvironmentValues {
    var app: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
