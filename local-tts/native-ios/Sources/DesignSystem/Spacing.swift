import CoreGraphics

/// Shared layout spacing values, so a gap repeated across screens stays in
/// sync as one number instead of drifting per call site. Several siblings
/// of `betweenSections` (a Home section's header-to-content gap, the gap
/// between Home's top-level groups) were removed with the Home sections
/// they described — this is the one survivor, now used by `ReadingStatsView`.
enum AppSpacing {
    static let betweenSections: CGFloat = 29
}
