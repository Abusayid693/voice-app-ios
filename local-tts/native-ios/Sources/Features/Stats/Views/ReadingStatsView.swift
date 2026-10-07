import CoreText
import LucideSwift
import SwiftUI
import UIKit

/// The retained Stats tab root — a GitHub-style contribution graph of
/// listening activity, with a tappable day showing per-book detail, plus
/// today's own date header and a half-circle goal gauge.
/// See `ReadingStatsViewModel` for how the graph is derived (SwiftData has
/// no raw `GROUP BY`, so the day-bucketing happens here in Swift over rows
/// already filtered by the background actor).
struct ReadingStatsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var viewModel: ReadingStatsViewModel
    @State private var contentRevealed = false
    let refreshToken: Int
    let isActive: Bool

    /// Today's listening goal, in minutes — a fixed target for now; there's
    /// no per-user goal setting yet.
    private let dailyGoalMinutes = 30

    init(readingStats: ReadingStatsStore, refreshToken: Int = 0, isActive: Bool = true) {
        _viewModel = StateObject(wrappedValue: ReadingStatsViewModel(store: readingStats))
        self.refreshToken = refreshToken
        self.isActive = isActive
    }

    var body: some View {
        NavigationStack {
            ZStack {
                TexturedDarkBackground(variant: .sidebar)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.betweenSections) {
                        StatsSignatureTitle(isRevealed: contentRevealed)
                            .frame(maxWidth: .infinity, alignment: .center)

                        currentDayHeader
                            .modifier(StatsEntranceReveal(isVisible: contentRevealed, delay: 0.10))

                        if viewModel.weeks.isEmpty {
                            emptyState
                                .modifier(StatsEntranceReveal(isVisible: contentRevealed, delay: 0.20))
                        } else {
                            ContributionGraphView(
                                weeks: viewModel.weeks, isRevealed: contentRevealed
                            ) { day in
                                Task { await viewModel.selectDay(day) }
                            }
                        }

                        dailyGoalGauge
                            .frame(maxWidth: .infinity)
                            .modifier(StatsEntranceReveal(
                                isVisible: contentRevealed, delay: gaugeRevealDelay))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 80)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task(id: refreshToken) { await viewModel.reload() }
        .task(id: EntranceTrigger(isActive: isActive, refreshToken: refreshToken, reduceMotion: reduceMotion)) {
            resetEntrance()
            guard isActive else { return }
            if !reduceMotion {
                // Commit the hidden starting pose before animating the retained tab.
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            contentRevealed = true
        }
        .onDisappear { resetEntrance() }
        .sheet(
            item: Binding(
                get: { viewModel.selectedDayDetail },
                set: { newValue in if newValue == nil { viewModel.clearSelectedDay() } })
        ) { detail in
            DayDetailView(detail: detail)
        }
    }

    private struct EntranceTrigger: Equatable {
        let isActive: Bool
        let refreshToken: Int
        let reduceMotion: Bool
    }

    private var gaugeRevealDelay: Double {
        let dayCount = viewModel.weeks.flatMap { $0 }.compactMap { $0 }.count
        let lastRow = max(0, (dayCount - 1) / ContributionGraphView.columnsPerRow)
        return StatsEntranceReveal.rowDelay(lastRow) + 0.20
    }

    private func resetEntrance() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { contentRevealed = false }
    }

    private static let currentDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMM, yyyy"
        return formatter
    }()

    private var currentDayHeader: some View {
        Text(Self.currentDayFormatter.string(from: Date()))
            .font(AppTextStyle.sectionTitle.font)
            .foregroundStyle(Color.appPrimaryText)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            LucideIcon(.chartColumn, style: .filled, size: 40, color: Color.appSecondaryText)
            Text("No reading activity yet")
                .font(AppTextStyle.body.font)
                .foregroundStyle(Color.appPrimaryText)
            Text("Finish listening to a page and it'll show up here.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var dailyGoalGauge: some View {
        let minutes = Int(viewModel.todayListenedSeconds / 60)
        let progress = dailyGoalMinutes > 0 ? Double(minutes) / Double(dailyGoalMinutes) : 0

        return VStack(spacing: 10) {
            HalfCircleGaugeView(progress: progress) {
                VStack(spacing: 2) {
                    Text("\(minutes)")
                        .font(AppTextStyle.title.font)
                        .foregroundStyle(Color.appPrimaryText)
                    Text(minutes == 1 ? "min read today" : "mins read today")
                        .font(AppTextStyle.labelDim.font)
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            Text("of \(dailyGoalMinutes) min goal")
                .font(AppTextStyle.meta.font)
                .foregroundStyle(Color.appSecondaryText)
        }
        .padding(.top, 8)
    }
}

/// Presentation-only outline drawing. The hidden Text reserves the final title's
/// layout; cached Core Text contours keep font shaping out of animation frames.
private struct StatsSignatureTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var fontSize: CGFloat = 36
    let isRevealed: Bool

    private static let font: UIFont = {
        let base = UIFont(name: "EBGaramond-Italic", size: 36)
            ?? UIFont.italicSystemFont(ofSize: 36)
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]
        ])
        return UIFont(descriptor: descriptor, size: 36)
    }()

    private static let artwork = StatsSignatureArtwork(font: font)

    var body: some View {
        Text("Reading Stats")
            .font(Font(Self.font.withSize(fontSize)))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .hidden()
            .overlay {
                StatsSignatureInk(
                    artwork: Self.artwork,
                    progress: reduceMotion || isRevealed ? 1 : 0)
                    .animation(
                        isRevealed && !reduceMotion ? .linear(duration: 1.15) : nil,
                        value: isRevealed)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading Stats")
            .accessibilityAddTraits(.isHeader)
    }
}

/// All coordinates are shaped once at 36pt, including kerning and italic overhang.
private struct StatsSignatureArtwork {
    let glyphs: [Path]
    let bounds: CGRect

    init(font: UIFont) {
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Reading Stats", attributes: [.font: font]))
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        var paths: [Path] = []
        var bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: ascent + descent)

        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            for index in 0..<count {
                guard let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], nil)
                else { continue } // Spaces advance the layout without a drawn contour.
                let path = Path(outline).applying(CGAffineTransform(
                    a: 1, b: 0, c: 0, d: -1,
                    tx: positions[index].x, ty: ascent - positions[index].y))
                paths.append(path)
                bounds = bounds.union(path.boundingRect)
            }
        }
        self.glyphs = paths
        self.bounds = bounds
    }
}

/// Only this small Canvas interpolates every frame; the Stats grid is unaffected.
private struct StatsSignatureInk: View, Animatable {
    let artwork: StatsSignatureArtwork
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let bounds = artwork.bounds
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            let transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale,
                tx: (size.width - bounds.width * scale) / 2 - bounds.minX * scale,
                ty: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)

            for (index, glyph) in artwork.glyphs.enumerated() {
                let start = Double(index) / Double(max(1, artwork.glyphs.count - 1)) * 0.68
                let drawn = min(1, max(0, (progress - start) / 0.32))
                guard drawn > 0 else { continue }
                let fillPhase = min(1, max(0, (drawn - 0.65) / 0.35))
                let fill = fillPhase * fillPhase * (3 - 2 * fillPhase)
                let path = glyph.applying(transform)

                context.stroke(
                    path.trimmedPath(from: 0, to: CGFloat(drawn)),
                    with: .color(Color.appPrimaryText.opacity(1 - fill)),
                    style: StrokeStyle(lineWidth: 0.75 * scale, lineCap: .round, lineJoin: .round))
                context.fill(path, with: .color(Color.appPrimaryText.opacity(fill)))
            }
        }
    }
}

/// Opacity and translation leave the final layout in place throughout the reveal.
struct StatsEntranceReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isVisible: Bool
    let delay: Double

    private let animationSpeedMultiplier = 1.2

    static func rowDelay(_ row: Int) -> Double { 0.20 + Double(row) * 0.022 }

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 10)
            .animation(
                isVisible && !reduceMotion
                    ? .easeOut(duration: 0.38 / animationSpeedMultiplier)
                        .delay(delay / animationSpeedMultiplier) : nil,
                value: isVisible)
            .allowsHitTesting(reduceMotion || isVisible)
            .accessibilityHidden(!reduceMotion && !isVisible)
    }
}

/// A gauge-style progress arc over the top half of a circle (flat edge at
/// the bottom, like a speedometer) — `content` sits inside the flat lower
/// half it leaves empty. Generic over its center content rather than a
/// fixed label, in case a future stat reuses the same shape.
private struct HalfCircleGaugeView<Content: View>: View {
    /// Not clamped internally — callers decide whether going over 1 should
    /// still read as "full" (clamped here) or, if ever wanted, overflow
    /// styling; today it's always clamped at the call site's math too since
    /// hitting/exceeding the goal both just mean "full arc".
    let progress: Double
    let content: () -> Content

    /// Sweeps from 0 up to `progress` once, animated, rather than the arc
    /// snapping straight to its resting value — separate from `progress`
    /// itself so a *later* real change (today's minutes ticking up while
    /// this page stays open) can re-animate too, via `.onChange` below,
    /// without re-triggering `.onAppear`'s one-time entrance sweep.
    @State private var animatedProgress: Double = 0

    private let diameter: CGFloat = 200
    private let lineWidth: CGFloat = 16

    init(progress: Double, @ViewBuilder content: @escaping () -> Content) {
        self.progress = progress
        self.content = content
    }

    private var clampedProgress: Double { min(max(progress, 0), 1) }

    var body: some View {
        ZStack(alignment: .top) {
            arc(from: 0.5, to: 1, color: Color.appPrimaryText.opacity(0.12))
            // Always present (not gated on progress > 0) so it has
            // something to animate *from* — conditionally inserting the
            // view at a later progress would just pop in at full length
            // instead of sweeping.
            arc(
                from: 0.5, to: 0.5 + 0.5 * animatedProgress,
                color: Color.appPrimaryText)
        }
        // A round `lineCap` stroke extends past the mathematical circle in
        // every direction it has an endpoint or apex — not just the top —
        // so clearance is needed on all 4 sides, not only a tight height
        // crop, or the cap at 12 o'clock (and the two arc ends at 9/3
        // o'clock) render visibly flattened where they'd cross frame 0.
        .padding(lineWidth / 2)
        // Only the height needs constraining — the padded width already
        // matches what should stay visible, nothing to crop horizontally.
        .frame(height: diameter / 2 + lineWidth, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            content()
                .padding(.bottom, 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) {
                animatedProgress = clampedProgress
            }
        }
        .onChange(of: progress) { _, _ in
            withAnimation(.easeOut(duration: 0.6)) {
                animatedProgress = clampedProgress
            }
        }
    }

    // Circle().trim(from: 0.5, to: 1) sweeps 9 o'clock -> 12 o'clock -> 3
    // o'clock, i.e. exactly the top half — no rotation needed, and that
    // upper half (plus the `lineWidth/2` clearance from the padding above)
    // is what the outer `.clipped()` frame keeps.
    private func arc(from: CGFloat, to: CGFloat, color: Color) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: diameter, height: diameter)
    }
}

#Preview {
    let dependencies = DependencyContainer()
    ReadingStatsView(readingStats: dependencies.readingStatsStore)
}
