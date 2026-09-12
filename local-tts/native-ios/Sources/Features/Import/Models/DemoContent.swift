import Foundation

/// Static placeholder content for the Import screen's remaining demo
/// section (Projects) — no backing data source yet, intentionally, per the
/// current design pass. Trending voices (ImportHomeView.voiceTiles) is real
/// data; What's trending's preview row is hand-curated (see
/// ImportHomeView.curatedTrendingBooks) while its "See all" screen stays
/// live via TrendingBooksViewModel/Gutendex.

struct DemoProject: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let updatedLabel: String
}

enum DemoContent {
    static let projects: [DemoProject] = [
        DemoProject(
            title: "Female narrator",
            subtitle: "Boundaries for Leaders — clinical psychologist...",
            updatedLabel: "Updated Sep 9, 2026")
    ]
}
