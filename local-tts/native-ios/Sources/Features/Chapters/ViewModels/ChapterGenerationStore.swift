import Foundation

/// Per-page Generate progress, keyed by `ReaderPageRef`. Owned at app
/// level (constructor-injected, like `VoicePackStore`) so a long page
/// synthesis survives page changes and navigation.
enum ChapterGenerationState: Equatable {
    case queued
    case running(done: Int, total: Int)
    case failed(String)
}

@MainActor
final class ChapterGenerationStore: ObservableObject {
    @Published private(set) var states: [ReaderPageRef: ChapterGenerationState] = [:]
    private var tasks: [ReaderPageRef: Task<Void, Never>] = [:]

    private let synthesisService: ChapterSynthesisService

    init(synthesisService: ChapterSynthesisService) {
        self.synthesisService = synthesisService
    }

    func state(for ref: ReaderPageRef) -> ChapterGenerationState? { states[ref] }
    func isGenerating(_ ref: ReaderPageRef) -> Bool { tasks[ref] != nil }

    /// No-op if this page is already generating — a second Generate tap
    /// while one's in flight shouldn't start a duplicate job.
    func generate(ref: ReaderPageRef, project: SavedGeneration, page: ReaderPage, voice: String) {
        guard tasks[ref] == nil else { return }
        states[ref] = .queued
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.synthesisService.generateAndSave(
                    ref: ref, project: project, page: page, voice: voice,
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
    /// (see `PageAudioStore`'s staging dir), so a later re-Generate
    /// resumes from where this left off rather than starting over.
    func cancel(_ ref: ReaderPageRef) {
        tasks[ref]?.cancel()
        tasks[ref] = nil
        states[ref] = nil
    }
}
