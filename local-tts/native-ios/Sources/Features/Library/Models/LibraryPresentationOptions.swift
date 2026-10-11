import Foundation

/// Persisted local presentation choices for the Library tab. They affect only
/// how existing library metadata is displayed; no project data is reordered.
enum LibraryFormatFilter: String, CaseIterable, Identifiable {
    case all
    case pdf
    case epub
    case text

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .text: "Text"
        }
    }

    func includes(_ source: SavedProjectSource) -> Bool {
        switch self {
        case .all: true
        case .pdf: source == .pdf
        case .epub: source == .epub
        case .text: source == .enteredText
        }
    }
}

/// Whether Library is showing the live collection or the archive — a
/// separate axis from `LibraryFormatFilter`, since a book's format and
/// whether it's archived are independent. Deliberately not a 5th
/// `LibraryFormatFilter` case: that `includes(_:)` is a pure function of
/// format, and an `.archived` case would force it to take a whole summary
/// and give every other case a second, unrelated responsibility.
enum LibraryArchiveScope: String {
    case active
    case archived
}

/// One pill in Library's filter row. The row is single-select, so these two
/// independent axes collapse into this one type for rendering/selection
/// only — neither `LibraryFormatFilter` nor `LibraryArchiveScope` is itself
/// persisted through it.
enum LibraryFilterPill: Hashable, Identifiable {
    case format(LibraryFormatFilter)
    case archived

    static let allPills: [LibraryFilterPill] =
        LibraryFormatFilter.allCases.map(Self.format) + [.archived]

    var id: String {
        switch self {
        case let .format(filter): "format-\(filter.rawValue)"
        case .archived: "archived"
        }
    }

    var title: String {
        switch self {
        case let .format(filter): filter.title
        case .archived: "Archived"
        }
    }
}

enum LibrarySortOrder: String {
    case recent
    case alphabetical

    var title: String {
        switch self {
        case .recent: "Recent"
        case .alphabetical: "A–Z"
        }
    }
}

enum LibraryLayoutMode: String {
    case list
    case grouped

    var title: String {
        switch self {
        case .list: "List"
        case .grouped: "Group by Month"
        }
    }
}

extension SavedProjectSource {
    var libraryFormatLabel: String {
        switch self {
        case .pdf: "PDF"
        case .epub: "EPUB"
        case .enteredText: "Text"
        case .unknown: "Document"
        }
    }
}
