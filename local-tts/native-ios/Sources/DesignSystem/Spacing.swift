import CoreGraphics

/// Shared layout spacing values, so a gap repeated across screens stays in
/// sync as one number instead of drifting per call site.
enum AppSpacing {
    /// Between a Home section's header (title, or title+subtitle) and its
    /// content below — Trending voices, Read Anything, Projects.
    static let sectionToContent: CGFloat = 19
    /// The same gap, but for a section nested inside another one's flow —
    /// Classic reads, New in romance.
    static let innerSectionToContent: CGFloat = 16
    /// Between siblings *within* one of Home's 4 top-level groups — e.g.
    /// Trending voices' list and "Create your own voice", or any of Read
    /// Anything/Classic reads/New in romance/"Create your own book" in
    /// sequence (Read Anything's own group).
    static let betweenSections: CGFloat = 29
    /// Between Home's 4 top-level groups themselves: the action buttons,
    /// Trending voices, Read Anything, Projects.
    static let betweenGroups: CGFloat = 40
}
