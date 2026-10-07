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
