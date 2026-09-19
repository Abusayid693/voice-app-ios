import Foundation

/// Per-chapter Generate progress, keyed by `ChapterRef`. Owned at app
/// level (constructor-injected, like `VoicePackStore`) rather than by
/// `ChaptersListView` — a 2-4 minute chapter synthesis must survive the
/// user navigating back to Library and returning, not restart every time
/// the list view appears.
enum ChapterGenerationState: Equatable {
    case queued
    case running(done: Int, total: Int)
    case failed(String)
}

@MainActor
final class ChapterGenerationStore: ObservableObject {
    @Published private(set) var states: [ChapterRef: ChapterGenerationState] = [:]
    private var tasks: [ChapterRef: Task<Void, Never>] = [:]

    private let synthesisService: ChapterSynthesisService

    init(synthesisService: ChapterSynthesisService) {
        self.synthesisService = synthesisService
    }

    func state(for ref: ChapterRef) -> ChapterGenerationState? { states[ref] }
    func isGenerating(_ ref: ChapterRef) -> Bool { tasks[ref] != nil }

    /// No-op if this chapter is already generating — a second Generate tap
    /// while one's in flight shouldn't start a duplicate job.
    func generate(ref: ChapterRef, project: SavedGeneration, chapter: Chapter, voice: String) {
        guard tasks[ref] == nil else { return }
        states[ref] = .queued
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synthesisService.generateAndSave(
                    ref: ref, project: project, chapter: chapter, voice: voice,
                    onProgress: { done, total in
                        Task { @MainActor in self.states[ref] = .running(done: done, total: total) }
                    })
                self.states[ref] = nil
                self.tasks[ref] = nil
            } catch is CancellationError {
                self.states[ref] = nil
                self.tasks[ref] = nil
            } catch {
                self.states[ref] = .failed(error.localizedDescription)
                self.tasks[ref] = nil
            }
        }
        tasks[ref] = task
    }

    /// Cancels an in-flight Generate. Already-staged chunks stay on disk
    /// (see `ChapterAudioStore`'s staging dir), so a later re-Generate
    /// resumes from where this left off rather than starting over.
    func cancel(_ ref: ChapterRef) {
        tasks[ref]?.cancel()
        tasks[ref] = nil
        states[ref] = nil
    }
}
