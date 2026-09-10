import SwiftUI

/// Static placeholder content for the Import screen's remaining demo
/// sections (What's trending / Projects) — no backing data source yet,
/// intentionally, per the current design pass. Trending voices is real
/// data (see ImportHomeView.voiceTiles), not demo content.

struct DemoBook: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let tint: Color
}

struct DemoProject: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let updatedLabel: String
}

enum DemoContent {
    // Public-domain titles — drawn as SwiftUI placeholder covers below
    // rather than fetched cover art, to avoid adding image-loading
    // infrastructure for demo-only content.
    static let trendingBooks: [DemoBook] = [
        DemoBook(title: "Good to Great", subtitle: "Jim Collins · Best in the Business", tint: .red),
        DemoBook(title: "Pride and Prejudice", subtitle: "Jane Austen · Reader Favorite", tint: .indigo),
        DemoBook(title: "Alice in Wonderland", subtitle: "Lewis Carroll · Classic", tint: .teal),
        DemoBook(title: "Moby-Dick", subtitle: "Herman Melville · Adventure", tint: .blue),
    ]

    static let projects: [DemoProject] = [
        DemoProject(
            title: "Female narrator",
            subtitle: "Boundaries for Leaders — clinical psychologist...",
            updatedLabel: "Updated Sep 9, 2026")
    ]
}
