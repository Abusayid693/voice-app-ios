import SwiftUI

/// Horizontal, snapping strip of `DayOrb`s — one real day per `DayActivity`
/// in `days` (oldest first, today last) plus a few faint, unselectable
/// future days trailing it. The centred orb renders larger via
/// `.scrollTransition`; `selectedDay` is a two-way binding so a tap on
/// `ContributionGraphView` below can re-centre this strip, and sliding this
/// strip updates what the graph and the summary card show.
///
/// Snapping recipe copied from `VoicePreviewSheet.swift`'s carousel — the
/// same three pitfalls apply here and are worth re-stating:
/// - `.scrollTargetBehavior(.viewAligned)` over `TabView(.page)`: page style
///   forces container-width items, so neighbouring orbs couldn't peek in.
/// - **Never** `.containerRelativeFrame` for the item width — it measures
///   the container *after* `contentMargins` has already inset it, which
///   would leave the resting orb off-centre.
/// - `.scrollPosition(id:)`'s initial value doesn't reliably land on first
///   render — an explicit `proxy.scrollTo(_:anchor:.center)` in `.onAppear`
///   is required, and is what actually gets this view to open on *today*
///   rather than the oldest day in the window.
struct DayOrbCarousel: View {
    let days: [DayActivity]
    @Binding var selectedDay: Date
    var isRevealed: Bool = true

    @State private var centeredDate: Date?
    private let calendar = Calendar.current

    private let itemWidth: CGFloat = 70
    private let itemSpacing: CGFloat = 16
    private let baseDiameter: CGFloat = 52
    /// Faint, unselectable days shown past today so the strip doesn't
    /// visually dead-end at the last real orb — matching the reference's
    /// right-hand diamonds. Scrolling onto one snaps straight back.
    private let futureDayCount = 3

    private var today: Date { calendar.startOfDay(for: Date()) }

    private var futureDays: [Date] {
        (1...futureDayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private func isFuture(_ date: Date) -> Bool { date > today }

    private func progress(for date: Date) -> Double {
        days.first { calendar.isDate($0.day, inSameDayAs: date) }?.goalProgress ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let inset = max((geometry.size.width - itemWidth) / 2, 0)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: itemSpacing) {
                        ForEach(days.map(\.day) + futureDays, id: \.self) { date in
                            DayOrb(
                                progress: progress(for: date), diameter: baseDiameter,
                                isFuture: isFuture(date)
                            )
                            .frame(width: itemWidth)
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.66)
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                            }
                            .id(date)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centeredDate)
                .contentMargins(.horizontal, inset, for: .scrollContent)
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(selectedDay, anchor: .center)
                }
                .onChange(of: centeredDate) { _, newValue in
                    guard let newValue else { return }
                    guard !isFuture(newValue) else {
                        // Rubber-band back to today rather than letting a
                        // future, data-less day become the selection.
                        withAnimation(.spring(duration: 0.4)) {
                            proxy.scrollTo(today, anchor: .center)
                        }
                        return
                    }
                    guard !calendar.isDate(newValue, inSameDayAs: selectedDay) else { return }
                    selectedDay = calendar.startOfDay(for: newValue)
                }
                .onChange(of: selectedDay) { _, newValue in
                    guard centeredDate.map({ !calendar.isDate($0, inSameDayAs: newValue) }) ?? true
                    else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        // Comfortably taller than the orb itself. The scroll view clips to
        // its own bounds, so anything an orb draws beyond this height comes
        // back as a flat-topped sphere — which is exactly what the earlier
        // outer glow did before it was removed.
        .frame(height: baseDiameter + 28)
        .modifier(StatsEntranceReveal(isVisible: isRevealed, delay: 0.10))
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var selected = Calendar.current.startOfDay(for: Date())
        var body: some View {
            let today = Calendar.current.startOfDay(for: Date())
            let days: [DayActivity] = (0..<90).map { offset in
                let day = Calendar.current.date(byAdding: .day, value: -offset, to: today)!
                return DayActivity(
                    day: day, listenedSeconds: Double([0, 300, 900, 1800, 2400].randomElement()!),
                    pagesCompleted: Int.random(in: 0...4),
                    goalSeconds: Double(DailyGoalSchedule.defaultGoalMinutes) * 60)
            }.reversed()
            DayOrbCarousel(days: Array(days), selectedDay: $selected)
                .padding(.vertical, 40)
                .background(Color.appBackground)
        }
    }
    return PreviewHost()
}
