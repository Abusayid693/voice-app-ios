import SwiftUI

/// One day's progress ring in `DayOrbCarousel` — a circle of small dots,
/// lit clockwise from the top starting at 12 o'clock, the fraction lit
/// equal to `progress` (0...1 toward `DayActivity.goalSeconds`). Replaced an
/// earlier solid-sphere version: a ring of discrete dots reads as a *count*
/// (how many of N steps are done) the way the reference design's own dotted
/// ring does, where a continuously warming sphere only read as "roughly how
/// full."
///
/// Hitting the goal adds a thin checkmark in the ring's own empty centre and
/// a small orange glow, so a met day is distinguishable from a
/// nearly-full ring at a glance rather than by counting dots.
struct DayOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0...1, already clamped by `DayActivity.goalProgress` — this view
    /// clamps again defensively since it has no other validation.
    let progress: Double
    var diameter: CGFloat = 52
    /// A day past today: every dot renders at its unlit color regardless of
    /// `progress` — there's nothing to report yet.
    var isFuture: Bool = false

    /// Dot count is fixed rather than scaled with `diameter` — the larger
    /// preview orb in `ChapterPlayerView`-style call sites should read as
    /// the *same* ring at a bigger size, not a higher-resolution one.
    ///
    /// Kept low relative to `dotDiameter`/`ringRadius` on purpose: at this
    /// orb's actual carousel size, the ring's circumference only has room
    /// for a dot roughly every 1.5 dot-widths before neighbours start
    /// touching — 28 was tuned against the much larger reference icon and
    /// overlapped into a solid line here. 16 leaves a visible gap on every
    /// side of each dot (center spacing ≈1.46× the dot's own diameter).
    private let dotCount = 16

    private var clamped: Double { min(max(progress, 0), 1) }
    private var isComplete: Bool { clamped >= 1 }
    private var litDotCount: Int { Int((Double(dotCount) * clamped).rounded()) }

    private var dotDiameter: CGFloat { diameter * 0.115 }
    private var ringRadius: CGFloat { diameter / 2 - dotDiameter / 2 - diameter * 0.015 }

    var body: some View {
        ZStack {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(dotColor(at: index))
                    .frame(width: dotDiameter, height: dotDiameter)
                    .offset(dotOffset(at: index))
            }

            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: diameter * 0.26, weight: .light))
                    .foregroundStyle(Color.tabSelected)
            }
        }
        .frame(width: diameter, height: diameter)
        // Sized to stay within the carousel row's own clearance — a halo
        // wider than this gets clipped by the scroll view's bounds, which
        // is what an earlier, larger glow on this view looked like.
        .shadow(
            color: isComplete ? Color.tabSelected.opacity(0.45) : .clear,
            radius: diameter * 0.14)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: progress)
    }

    /// Clockwise from 12 o'clock, matching the reference's own fill
    /// direction and reading the same way a clock face or a loading ring
    /// does — `-90°` is `SwiftUI`'s top in `Angle` terms (`0°` is 3 o'clock).
    private func dotOffset(at index: Int) -> CGSize {
        let angle = Angle.degrees(-90 + 360 * Double(index) / Double(dotCount))
        return CGSize(
            width: CGFloat(cos(angle.radians)) * ringRadius,
            height: CGFloat(sin(angle.radians)) * ringRadius)
    }

    private func dotColor(at index: Int) -> Color {
        guard !isFuture else { return Color.appPrimaryText.opacity(0.10) }
        // The same coral `AppTabBar` uses for the active tab, so a
        // completed day and the selected Stats tab icon read as one color
        // rather than two different "this matters" accents on screen.
        return index < litDotCount
            ? Color.tabSelected
            : Color.appPrimaryText.opacity(0.16)
    }
}

#Preview {
    HStack(spacing: 18) {
        DayOrb(progress: 0)
        DayOrb(progress: 0.25)
        DayOrb(progress: 0.5)
        DayOrb(progress: 0.8)
        DayOrb(progress: 1, diameter: 64)
        DayOrb(progress: 0, isFuture: true)
    }
    .padding(40)
    .background(Color.appBackground)
}
