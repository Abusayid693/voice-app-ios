import SwiftUI

/// The app's long-lived observable objects, bundled so intermediate views
/// stop forwarding ones they never read (`RootTabView` used to take six
/// parameters purely to hand them to its tab roots; now it takes this one).
///
/// Deliberately a plain `struct`, **not** an `ObservableObject`: holding it
/// as a plain `let` subscribes a view to nothing at all. That matters here —
/// this app's re-render discipline (see CLAUDE.md: "object granularity *is*
/// re-render granularity") depends on a view observing only the objects it
/// actually reads. A view that needs to *observe* an object still takes that
/// one object as an explicit `@ObservedObject` parameter from its parent, so
/// the subscription stays narrow and visible; this container only removes
/// the pass-through burden for objects a view merely hands onward.
///
/// Passed explicitly as a `let` rather than through `@Environment` with a
/// custom `EnvironmentKey`. That was tried first and crashed on-device:
/// `EnvironmentKey` requires a `defaultValue`, every object in here needs a
/// real `DependencyContainer` (so there's no cheap safe default to give),
/// and a `fatalError` default gets evaluated by SwiftUI in more situations
/// than just "nobody injected this". A required dependency isn't what
/// `EnvironmentKey` is for — an explicit parameter can't fail.
struct AppEnvironment {
    let tts: TTSViewModel
    let voiceClone: VoiceCloneViewModel
    let library: LibraryViewModel
    let pdfImports: PDFImportManager
    let previewPlayer: VoicePreviewPlayer
    let chapterPlayer: ChapterAudioPlayer
    let generationStore: ChapterGenerationStore
    // Not "pass-through" like the others above — a live flag tab roots
    // write to and RootTabView observes, so RootTabView's custom bottom
    // bar (tabs + "+", all in one row — see CustomTabBar) can hide itself
    // on pushed screens. See NavigationChromeVisibility's own doc comment.
    let navigationChrome: NavigationChromeVisibility
}

extension AppEnvironment {
    /// A throwaway object graph for `#Preview` only — previews render a
    /// real view hierarchy, so they need the same objects passed in that
    /// `KokoroAneTestApp` passes at launch.
    @MainActor
    static func preview() -> AppEnvironment {
        let dependencies = DependencyContainer()
        let tts = TTSViewModel(dependencies: dependencies)
        let synthesis = ChapterSynthesisService(kokoroServices: tts.kokoroServices)
        let library = LibraryViewModel()
        return AppEnvironment(
            tts: tts, voiceClone: VoiceCloneViewModel(dependencies: dependencies),
            library: library, pdfImports: PDFImportManager(library: library), previewPlayer: VoicePreviewPlayer(),
            chapterPlayer: ChapterAudioPlayer(synthesisService: synthesis),
            generationStore: ChapterGenerationStore(synthesisService: synthesis),
            navigationChrome: NavigationChromeVisibility())
    }
}
