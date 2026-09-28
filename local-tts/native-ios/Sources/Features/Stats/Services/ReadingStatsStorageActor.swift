import Foundation
import SwiftData

/// Every SwiftData read/write for this feature happens here, off the main
/// actor — see `ReadingStatsStore`'s and this feature's own performance
/// notes: `ChapterPlayerView`'s read-along is the most performance-tuned
/// surface in this app, and a `context.save()` on the main thread during
/// playback would land squarely in the window `TimelineView` is polling
/// word highlights. `@ModelActor` synthesizes `modelContainer`/
/// `modelContext` and an initializer taking the container.
@ModelActor
actor ReadingStatsStorageActor {
    /// Inserts a session immediately (before any audio has actually played)
    /// so it exists on disk as soon as a listen starts, not only once it ends.
    func insertSession(
        id: UUID, startedAt: Date, projectID: UUID, bookTitle: String, pageIndex: Int,
        voiceName: String, engine: Engine
    ) throws {
        let session = ReadingSession(
            id: id, startedAt: startedAt, projectID: projectID, bookTitle: bookTitle,
            pageIndex: pageIndex, voiceName: voiceName, engine: engine)
        modelContext.insert(session)
        try modelContext.save()
    }

    /// The periodic/pause checkpoint — assigns the absolute total, never
    /// `+=`, so a duplicated or retried call can't double-count.
    func updateListenedSeconds(sessionID: UUID, listenedSeconds: Double) throws {
        guard let session = try session(id: sessionID) else { return }
        session.listenedSeconds = listenedSeconds
        try modelContext.save()
    }

    /// Final write for a session — natural finish or explicit stop, told
    /// apart by `pageCompleted`.
    func endSession(
        sessionID: UUID, listenedSeconds: Double, endedAt: Date, pageCompleted: Bool
    ) throws {
        guard let session = try session(id: sessionID) else { return }
        session.listenedSeconds = listenedSeconds
        session.endedAt = endedAt
        session.pageCompleted = pageCompleted
        try modelContext.save()
    }

    /// Run once at launch. A session with `endedAt == nil` means the app
    /// was killed mid-listen — close it out with whatever `listenedSeconds`
    /// it last had checkpointed (or drop it if that's negligible) so it
    /// doesn't stay "open" forever and never count toward a day.
    @discardableResult
    func closeStaleSessions(now: Date, droppedBelowSeconds: Double = 1) throws -> Int {
        let descriptor = FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.endedAt == nil })
        let stale = try modelContext.fetch(descriptor)
        for session in stale {
            if session.listenedSeconds < droppedBelowSeconds {
                modelContext.delete(session)
            } else {
                session.endedAt = now
                // Not observed finishing, so it can't be a completed page.
                session.pageCompleted = false
            }
        }
        if !stale.isEmpty { try modelContext.save() }
        return stale.count
    }

    /// Distinct pages with at least one completed listen, for a project —
    /// feeds the page-picker tick, the reader header tick, and the Book
    /// Shelf progress bar. Re-reading a page doesn't inflate this: it's a
    /// Set, not a count of sessions.
    func completedPageIndices(forProject projectID: UUID) throws -> Set<Int> {
        let descriptor = FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.projectID == projectID && $0.pageCompleted == true })
        let sessions = try modelContext.fetch(descriptor)
        return Set(sessions.map(\.pageIndex))
    }

    /// Every session that overlaps `[start, end)` by start date — the raw
    /// material `ReadingStatsViewModel` groups/sums in Swift (SwiftData has
    /// no raw `GROUP BY`; see the plan's Storage section).
    func sessions(from start: Date, to end: Date) throws -> [ReadingSessionSnapshot] {
        let descriptor = FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt)])
        return try modelContext.fetch(descriptor).map(ReadingSessionSnapshot.init)
    }

    /// Every session for one project, most recent first — feeds the day
    /// detail's "books read" rows when later widened to per-project history,
    /// and is the simplest correct thing for `Not in scope`'s deferred
    /// per-project stats.
    func sessions(forProject projectID: UUID) throws -> [ReadingSessionSnapshot] {
        let descriptor = FetchDescriptor<ReadingSession>(
            predicate: #Predicate { $0.projectID == projectID },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map(ReadingSessionSnapshot.init)
    }

    private func session(id: UUID) throws -> ReadingSession? {
        var descriptor = FetchDescriptor<ReadingSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
