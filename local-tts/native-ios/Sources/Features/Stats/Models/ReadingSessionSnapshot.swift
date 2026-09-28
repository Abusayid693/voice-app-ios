import Foundation

/// A plain, `Sendable` copy of a `ReadingSession` row — `@Model` classes
/// aren't `Sendable`, so anything crossing from `ReadingStatsStorageActor`
/// (background) back to a `@MainActor` caller goes through this instead of
/// the model type itself.
struct ReadingSessionSnapshot: Sendable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let listenedSeconds: Double
    let projectID: UUID
    let bookTitle: String
    let pageIndex: Int
    let pageCompleted: Bool
    let voiceName: String
    let engineRawValue: String

    var engine: Engine? { Engine(rawValue: engineRawValue) }

    init(_ session: ReadingSession) {
        id = session.id
        startedAt = session.startedAt
        endedAt = session.endedAt
        listenedSeconds = session.listenedSeconds
        projectID = session.projectID
        bookTitle = session.bookTitle
        pageIndex = session.pageIndex
        pageCompleted = session.pageCompleted
        voiceName = session.voiceName
        engineRawValue = session.engineRawValue
    }
}
