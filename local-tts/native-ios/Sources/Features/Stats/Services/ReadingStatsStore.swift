import Foundation
import SwiftData

/// Owns the SwiftData `ModelContainer` for reading stats and forwards every
/// call to `ReadingStatsStorageActor` (background) — nothing here runs
/// SwiftData work on the caller's actor, every method here is `async` and
/// awaits the background actor. First use of SwiftData in this app;
/// everything else is hand-written JSON (see `SavedGeneration`) — chosen
/// here specifically for real predicated queries and a real schema
/// migration path, since this feature's explicit requirement is being
/// extended with more stat types later.
///
/// Constructed lazily (see `DependencyContainer.readingStatsStore`) so
/// store setup doesn't tax cold launch, and resilient to failure: if the
/// on-disk store can't be opened, falls back to an in-memory configuration
/// rather than crashing the app over a non-critical, additive feature —
/// stats just won't persist across launches in that (unexpected) case.
final class ReadingStatsStore {
    private let storageActor: ReadingStatsStorageActor

    init() {
        let schema = Schema([ReadingSession.self])
        let configuration = ModelConfiguration(schema: schema, url: Self.storeURL())
        let container: ModelContainer
        if let onDisk = try? ModelContainer(for: schema, configurations: [configuration]) {
            container = onDisk
        } else {
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try — an in-memory container has
            // no real failure mode; this is the last-resort fallback itself.
            container = try! ModelContainer(for: schema, configurations: [inMemory])
        }
        storageActor = ReadingStatsStorageActor(modelContainer: container)
    }

    private static func storeURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("ReadingStatsV1", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("ReadingStats.store")
    }

    // MARK: - Capture (called by ReadingStatsTracker)

    func insertSession(
        id: UUID, startedAt: Date, projectID: UUID, bookTitle: String, pageIndex: Int,
        voiceName: String, engine: Engine
    ) async {
        try? await storageActor.insertSession(
            id: id, startedAt: startedAt, projectID: projectID, bookTitle: bookTitle,
            pageIndex: pageIndex, voiceName: voiceName, engine: engine)
    }

    func updateListenedSeconds(sessionID: UUID, listenedSeconds: Double) async {
        try? await storageActor.updateListenedSeconds(
            sessionID: sessionID, listenedSeconds: listenedSeconds)
    }

    func endSession(
        sessionID: UUID, listenedSeconds: Double, endedAt: Date, pageCompleted: Bool
    ) async {
        try? await storageActor.endSession(
            sessionID: sessionID, listenedSeconds: listenedSeconds, endedAt: endedAt,
            pageCompleted: pageCompleted)
    }

    /// Call once at launch, off the main thread — see this feature's
    /// performance notes on lazy/async startup work.
    func closeStaleSessionsAtLaunch() async {
        try? await storageActor.closeStaleSessions(now: Date())
    }

    // MARK: - Reads

    func completedPageIndices(forProject projectID: UUID) async -> Set<Int> {
        (try? await storageActor.completedPageIndices(forProject: projectID)) ?? []
    }

    func sessions(from start: Date, to end: Date) async -> [ReadingSessionSnapshot] {
        (try? await storageActor.sessions(from: start, to: end)) ?? []
    }

    func sessions(forProject projectID: UUID) async -> [ReadingSessionSnapshot] {
        (try? await storageActor.sessions(forProject: projectID)) ?? []
    }
}
