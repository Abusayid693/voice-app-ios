import SwiftUI

/// Static placeholder content for the Import screen's demo sections
/// (Trending voices / What's trending / Projects) — no backing data source
/// yet, intentionally, per the current design pass.

struct DemoVoice: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let tint: Color
}

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
    static let trendingVoices: [DemoVoice] = [
        DemoVoice(name: "Alexandra", subtitle: "Conversational and natural", tint: .pink),
        DemoVoice(name: "Alex", subtitle: "Warm storyteller · informative", tint: .purple),
    ]

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
