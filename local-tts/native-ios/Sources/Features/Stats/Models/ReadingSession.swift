import Foundation
import SwiftData

/// One listening session for one reader page — never pre-aggregated. Every
/// stat this feature shows (and every one added later) is a query over raw
/// rows like this, not separately maintained counters, so a new metric
/// never needs new capture code, only a new fetch.
///
/// `bookTitle` is denormalized rather than looked up via `projectID` at
/// display time — `LibraryViewModel.delete(_:)` removes project metadata
/// entirely, and past days should still show what was read even after the
/// project itself is gone.
///
/// Forward-compatible via SwiftData's own migration story rather than this
/// app's usual `decodeIfPresent ?? default` JSON convention (see
/// `SavedGeneration.init(from:)`): a later-added optional property is a
/// lightweight (automatic) migration, and anything structural gets a real
/// `VersionedSchema`/`SchemaMigrationPlan`.
@Model
final class ReadingSession {
    #Index<ReadingSession>([\.projectID], [\.endedAt])

    var id: UUID
    var startedAt: Date
    /// nil while the session is still in progress. A session found with
    /// this still nil at launch (see `ReadingStatsStore`) means the app was
    /// killed mid-session and gets closed out rather than left open forever.
    var endedAt: Date?
    /// Listening time only — accrues while audio is actually playing, not
    /// while paused. Always the absolute total-so-far, never incremented in
    /// place, so a duplicated or retried write can't double-count.
    var listenedSeconds: Double
    var projectID: UUID
    var bookTitle: String
    var pageIndex: Int
    /// True only when this specific listen reached the end of the page's
    /// audio — set from the engine-specific "audio actually finished"
    /// signal, not from synthesis finishing or the page merely changing.
    var pageCompleted: Bool
    /// The voice actually in use when this session started — the reader's
    /// live selection, not necessarily the project's saved default (voice
    /// can change mid-reader).
    var voiceName: String
    /// `Engine`'s raw value. Stored as a plain String rather than the enum
    /// directly so a future engine case (or a renamed one) can never fail
    /// to decode an old row — `engineValue` below degrades to `nil` instead.
    var engineRawValue: String

    var engine: Engine? { Engine(rawValue: engineRawValue) }

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        listenedSeconds: Double = 0,
        projectID: UUID,
        bookTitle: String,
        pageIndex: Int,
        pageCompleted: Bool = false,
        voiceName: String,
        engine: Engine
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.listenedSeconds = listenedSeconds
        self.projectID = projectID
        self.bookTitle = bookTitle
        self.pageIndex = pageIndex
        self.pageCompleted = pageCompleted
        self.voiceName = voiceName
        self.engineRawValue = engine.rawValue
    }
}
