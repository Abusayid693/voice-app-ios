import Combine
import Foundation

/// One import cover's frequently changing UI state. Updating it does not
/// publish through the structural shelf store, so existing book geometry stays stable.
@MainActor
final class PDFImportShelfItem: ObservableObject, Identifiable {
    let id: UUID
    let title: String
    let createdAt: Date
    let shelfOrder: Int
    let storedCoverURL: URL
    // Lifecycle bookkeeping only; does not republish progress or shelf geometry.
    var presentationCount = 0

    @Published private(set) var phase: PDFImportPhase
    @Published private(set) var progress: Double
    @Published private(set) var isCoverReady: Bool
    @Published private(set) var errorMessage: String?

    init(job: PDFImportJob) {
        id = job.id
        title = job.sourceFileName
        createdAt = job.createdAt
        shelfOrder = job.shelfOrder ?? 0
        storedCoverURL = job.coverURL
        phase = job.phase
        progress = job.progress
        isCoverReady = FileManager.default.fileExists(atPath: job.coverURL.path)
        errorMessage = job.errorMessage
    }

    var coverURL: URL? { isCoverReady ? storedCoverURL : nil }
    var isFailed: Bool { phase == .failed }
    var isCompleted: Bool { phase == .completed }

    func apply(_ job: PDFImportJob, coverAvailable: Bool? = nil) {
        phase = job.phase
        progress = job.progress
        isCoverReady = coverAvailable
            ?? FileManager.default.fileExists(atPath: job.coverURL.path)
        errorMessage = job.errorMessage
    }
}

/// Publishes only additions/removals. Page progress lives on each child item.
@MainActor
final class PDFImportShelfStore: ObservableObject {
    @Published private(set) var items: [PDFImportShelfItem]

    init(jobs: [PDFImportJob]) {
        items = jobs
            .filter { $0.phase != .completed && $0.phase != .cancelled }
            .map(PDFImportShelfItem.init)
            .sorted { $0.shelfOrder < $1.shelfOrder }
    }

    func insert(_ job: PDFImportJob) {
        guard !items.contains(where: { $0.id == job.id }) else {
            update(job)
            return
        }
        items.append(PDFImportShelfItem(job: job))
        items.sort { $0.shelfOrder < $1.shelfOrder }
    }

    func update(_ job: PDFImportJob, coverAvailable: Bool? = nil) {
        if let item = items.first(where: { $0.id == job.id }) {
            item.apply(job, coverAvailable: coverAvailable)
        } else if job.phase != .completed && job.phase != .cancelled {
            insert(job)
        }
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func finishPresentation(id: UUID) {
        guard items.first(where: { $0.id == id })?.isCompleted == true else { return }
        remove(id: id)
    }
}
