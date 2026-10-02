import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Main-actor facade for durable PDF jobs. It owns UI-facing state and hands
/// expensive work to `PDFProcessingActor`, while every meaningful transition
/// is atomically persisted for relaunch/background recovery.
@MainActor
final class PDFImportManager: ObservableObject {
    static let backgroundTaskIdentifier = "com.rehanchoudhury.kokoroanetest.pdf-import"

    @Published private(set) var jobs: [PDFImportJob] = []
    let shelfStore: PDFImportShelfStore

    private let library: LibraryViewModel
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    init(library: LibraryViewModel) {
        self.library = library
        var restoredJobs = Self.loadJobs()
        Self.assignMissingShelfOrders(to: &restoredJobs, library: library)
        jobs = restoredJobs
        shelfStore = PDFImportShelfStore(jobs: restoredJobs)
        persistJobs()
        Task { await resumeInterruptedJobs() }
    }

    /// Copies the picked file while its security-scoped permission is active,
    /// then starts a utility-priority parse that does not block the picker or
    /// SwiftUI's main actor.
    func importPDF(from url: URL, engine: Engine, voiceName: String) async {
        let job = PDFImportJob(
            sourceFileName: FileNameFormatter.displayTitle(from: url.lastPathComponent),
            engine: engine, voiceName: voiceName, shelfOrder: nextShelfOrder())
        // Reserve the shelf slot before copying or parsing begins. Large files
        // therefore cannot make the rest of the shelf jump when they finish.
        jobs.insert(job, at: 0)
        shelfStore.insert(job)
        persistJobs()

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                try fileManager.createDirectory(at: job.directory, withIntermediateDirectories: true)
                try fileManager.createDirectory(at: job.pagesDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: url, to: job.sourceURL)
            }.value
            requestCompletionNotificationsIfNeeded()
            beginProcessing(job.id)
        } catch {
            update(job.id) {
                $0.phase = .failed
                $0.errorMessage = "Could not copy the selected PDF: \(error.localizedDescription)"
                $0.updatedAt = Date()
            }
        }
    }

    func retry(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        retry(job)
    }

    func retry(_ job: PDFImportJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].phase = .queued
        jobs[index].errorMessage = nil
        jobs[index].overallProgress = 0
        jobs[index].completedPages = 0
        jobs[index].updatedAt = Date()
        shelfStore.update(jobs[index])
        persistJobs()
        beginProcessing(job.id)
    }

    func cancel(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        cancel(job)
    }

    func cancel(_ job: PDFImportJob) {
        processingTasks[job.id]?.cancel()
        update(job.id) {
            $0.phase = .cancelled
            $0.updatedAt = Date()
        }
        shelfStore.remove(id: job.id)
    }

    func delete(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        delete(job)
    }

    func delete(_ job: PDFImportJob) {
        processingTasks[job.id]?.cancel()
        processingTasks[job.id] = nil
        jobs.removeAll { $0.id == job.id }
        shelfStore.remove(id: job.id)
        persistJobs()
        try? FileManager.default.removeItem(at: job.directory)
    }

    func applicationDidEnterBackground() {
        // A short grace period is only for durably recording the latest
        // checkpoint and submitting the real BGProcessingTask request. It is
        // deliberately not used to promise uninterrupted PDF parsing.
        let checkpointTask = UIApplication.shared.beginBackgroundTask(withName: "PDF import checkpoint")
        defer { UIApplication.shared.endBackgroundTask(checkpointTask) }
        persistJobs()
        scheduleBackgroundContinuation()
    }

    /// Registers once at app launch. iOS invokes this handler opportunistically
    /// for unfinished work; checkpoints make repeated starts harmless.
    static func registerBackgroundTask(manager: PDFImportManager) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: backgroundTaskIdentifier, using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            processingTask.expirationHandler = {
                Task { @MainActor in manager.cancelActiveProcessingForSystemExpiration() }
            }
            Task { @MainActor in
                await manager.resumeInterruptedJobs()
                processingTask.setTaskCompleted(success: true)
            }
        }
    }

    private func beginProcessing(_ id: UUID) {
        guard processingTasks[id] == nil else { return }
        processingTasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(id)
        }
    }

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), !job.phase.isTerminal else {
            processingTasks[id] = nil
            return
        }
        defer { processingTasks[id] = nil }
        let processor = PDFProcessingActor()
        update(id) {
            $0.phase = .validating
            $0.errorMessage = nil
            $0.updatedAt = Date()
        }

        do {
            let result = try await processor.process(job: job) { [weak self] progress in
                self?.receive(progress, for: id)
            }
            guard !Task.isCancelled else { return }
            guard let projectID = library.saveImportedPDF(
                id: job.id, title: result.title, createdAt: job.createdAt,
                shelfOrder: job.shelfOrder, pagesDirectory: result.pagesDirectory,
                sourceURL: result.sourceURL,
                pageCount: result.pageCount, coverURL: result.coverURL,
                spineArtworkURL: result.spineArtworkURL,
                engine: job.engine, voiceName: job.voiceName
            ) else {
                throw PDFImportError.noReadableContent
            }
            update(id) {
                $0.phase = .completed
                $0.completedPages = $0.totalPages
                $0.overallProgress = 1
                $0.projectID = projectID
                $0.errorMessage = nil
                $0.updatedAt = Date()
            }
            // Visible covers hand off after their actual settling animation, not a timer.
            if shelfStore.items.first(where: { $0.id == id })?.presentationCount == 0 {
                shelfStore.finishPresentation(id: id)
            }
            sendCompletionNotification(for: job)
        } catch is CancellationError {
            if jobs.first(where: { $0.id == id })?.phase != .cancelled {
                update(id) {
                    $0.phase = .queued
                    $0.updatedAt = Date()
                }
                scheduleBackgroundContinuation()
            }
        } catch {
            update(id) {
                $0.phase = .failed
                $0.errorMessage = error.localizedDescription
                $0.updatedAt = Date()
            }
        }
    }

    private func receive(_ progress: PDFProcessingProgress, for id: UUID) {
        update(id, coverAvailable: progress.coverAvailable) {
            $0.phase = progress.phase
            $0.totalPages = progress.totalPages
            $0.completedPages = progress.completedPages
            $0.overallProgress = max($0.overallProgress ?? 0, progress.overallProgress)
            $0.updatedAt = Date()
        }
    }

    private func update(
        _ id: UUID, coverAvailable: Bool? = nil,
        mutation: (inout PDFImportJob) -> Void
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
        shelfStore.update(jobs[index], coverAvailable: coverAvailable)
        persistJobs()
    }

    private func resumeInterruptedJobs() async {
        let resumable = jobs.filter { !$0.phase.isTerminal }.map(\.id)
        for id in resumable where processingTasks[id] == nil {
            let task: Task<Void, Never> = Task { [weak self] in
                guard let self else { return }
                await self.run(id)
            }
            processingTasks[id] = task
            await task.value
        }
    }

    private func cancelActiveProcessingForSystemExpiration() {
        for task in processingTasks.values { task.cancel() }
    }

    private func scheduleBackgroundContinuation() {
        guard jobs.contains(where: { !$0.phase.isTerminal }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func loadJobs() -> [PDFImportJob] {
        guard let data = try? Data(contentsOf: PDFImportJob.indexURL) else { return [] }
        return (try? JSONDecoder().decode([PDFImportJob].self, from: data)) ?? []
    }

    private func nextShelfOrder() -> Int {
        let savedPDFs = library.savedGenerations.filter { $0.source == .pdf }
        let legacyLast = savedPDFs.filter { $0.shelfOrder == nil }.count - 1
        let savedLast = savedPDFs.compactMap(\.shelfOrder).max() ?? -1
        let jobLast = jobs.compactMap(\.shelfOrder).max() ?? -1
        return max(legacyLast, savedLast, jobLast) + 1
    }

    private static func assignMissingShelfOrders(
        to jobs: inout [PDFImportJob], library: LibraryViewModel
    ) {
        let savedPDFs = library.savedGenerations.filter { $0.source == .pdf }
        let legacyLast = savedPDFs.filter { $0.shelfOrder == nil }.count - 1
        let savedLast = savedPDFs.compactMap(\.shelfOrder).max() ?? -1
        var next = max(
            legacyLast, savedLast,
            jobs.compactMap(\.shelfOrder).max() ?? -1) + 1
        let missing = jobs.indices
            .filter { jobs[$0].shelfOrder == nil }
            .sorted { jobs[$0].createdAt < jobs[$1].createdAt }
        for index in missing {
            jobs[index].shelfOrder = next
            next += 1
        }
    }

    private func persistJobs() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: PDFImportJob.baseDirectory, withIntermediateDirectories: true)
        try? data.write(to: PDFImportJob.indexURL, options: .atomic)
    }

    private func requestCompletionNotificationsIfNeeded() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    private func sendCompletionNotification(for job: PDFImportJob) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "PDF ready to read"
        content.body = "\(job.sourceFileName) has been added to your library."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "pdf-import-\(job.id.uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
