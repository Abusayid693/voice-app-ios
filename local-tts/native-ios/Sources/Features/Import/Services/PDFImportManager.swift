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
    @Published var isDocumentPickerPresented = false

    private let library: LibraryViewModel
    private var processingTasks: [UUID: Task<Void, Never>] = [:]

    init(library: LibraryViewModel) {
        self.library = library
        jobs = Self.loadJobs()
        Task { await resumeInterruptedJobs() }
    }

    func requestDocumentPicker() {
        isDocumentPickerPresented = true
    }

    /// Copies the picked file while its security-scoped permission is active,
    /// then starts a utility-priority parse that does not block the picker or
    /// SwiftUI's main actor.
    func importPDF(from url: URL, engine: Engine, voiceName: String) async {
        let job = PDFImportJob(
            sourceFileName: url.deletingPathExtension().lastPathComponent,
            engine: engine, voiceName: voiceName)
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
            jobs.insert(job, at: 0)
            persistJobs()
            requestCompletionNotificationsIfNeeded()
            beginProcessing(job.id)
        } catch {
            var failed = job
            failed.phase = .failed
            failed.errorMessage = "Could not copy the selected PDF: \(error.localizedDescription)"
            failed.updatedAt = Date()
            jobs.insert(failed, at: 0)
            persistJobs()
        }
    }

    func retry(_ job: PDFImportJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index].phase = .queued
        jobs[index].errorMessage = nil
        jobs[index].updatedAt = Date()
        persistJobs()
        beginProcessing(job.id)
    }

    func cancel(_ job: PDFImportJob) {
        processingTasks[job.id]?.cancel()
        update(job.id) {
            $0.phase = .cancelled
            $0.updatedAt = Date()
        }
    }

    func delete(_ job: PDFImportJob) {
        processingTasks[job.id]?.cancel()
        processingTasks[job.id] = nil
        jobs.removeAll { $0.id == job.id }
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
                title: result.title, pagesDirectory: result.pagesDirectory,
                pageCount: result.pageCount, coverURL: result.coverURL,
                engine: job.engine, voiceName: job.voiceName
            ) else {
                throw PDFImportError.noReadableContent
            }
            update(id) {
                $0.phase = .completed
                $0.completedPages = $0.totalPages
                $0.projectID = projectID
                $0.errorMessage = nil
                $0.updatedAt = Date()
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
        update(id) {
            $0.phase = progress.phase
            $0.totalPages = progress.totalPages
            $0.completedPages = progress.completedPages
            $0.updatedAt = Date()
        }
    }

    private func update(_ id: UUID, mutation: (inout PDFImportJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&jobs[index])
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
