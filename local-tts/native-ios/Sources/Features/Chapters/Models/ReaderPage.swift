import Foundation

/// One user-visible reading page. PDF imports preserve the source PDF's
/// physical page indexes; typed text is split into pages of at most 2,000
/// words before these values are persisted independently on disk.
struct ReaderPage: Codable, Identifiable, Hashable, Sendable {
    let index: Int
    let text: String

    var id: Int { index }
    var number: Int { index + 1 }
    var title: String { "Page \(number)" }
}

/// The small, display-only representation used by the page picker. It keeps
/// a large project's picker from retaining every page's complete text.
struct ReaderPagePreview: Identifiable, Hashable, Sendable {
    let index: Int
    let excerpt: String
    let isBlank: Bool

    var id: Int { index }
    var number: Int { index + 1 }
}
