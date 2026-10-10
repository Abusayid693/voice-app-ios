import Foundation
import SwiftUI

/// Library tab root. Filtering and arrangement are local presentation state;
/// project opening and deletion stay delegated to the shared library model.
struct LibraryTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenProject: (SavedGeneration) -> Void

    @AppStorage("library.formatFilter") private var formatFilterRawValue = LibraryFormatFilter.all.rawValue
    @AppStorage("library.sortOrder") private var sortOrderRawValue = LibrarySortOrder.recent.rawValue
    @AppStorage("library.layoutMode") private var layoutModeRawValue = LibraryLayoutMode.grouped.rawValue
    @State private var isArrangementSheetPresented = false
    /// At most one row's actions are open at a time — setting this to a new
    /// id implicitly closes whichever row had it before, the same way
    /// opening one swipe-action row on a native List closes any other.
    @State private var revealedGenerationID: UUID?

    private var formatFilter: LibraryFormatFilter {
        LibraryFormatFilter(rawValue: formatFilterRawValue) ?? .all
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRawValue) ?? .recent
    }

    private var layoutMode: LibraryLayoutMode {
        LibraryLayoutMode(rawValue: layoutModeRawValue) ?? .grouped
    }

    private var sortedGenerations: [SavedGenerationSummary] {
        viewModel.savedGenerations
            .filter { formatFilter.includes($0.source) }
            .sorted(by: isInDisplayOrder)
    }

    private var groupedGenerations: [LibraryGenerationSection] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: sortedGenerations) {
            LibraryGenerationSectionKey(date: $0.createdAt, calendar: calendar)
        }

        return groups.map { key, generations in
            LibraryGenerationSection(
                key: key,
                generations: generations,
                mostRecentDate: generations.map(\.createdAt).max() ?? .distantPast)
        }
        .sorted { lhs, rhs in
            lhs.mostRecentDate == rhs.mostRecentDate
                ? lhs.key.title < rhs.key.title
                : lhs.mostRecentDate > rhs.mostRecentDate
        }
    }

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                header
                formatFilters
                libraryContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isArrangementSheetPresented) {
            LibraryArrangementSheet(
                sortOrder: sortOrderBinding,
                layoutMode: layoutModeBinding)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Library")
                .font(.custom("EBGaramond-Regular", size: 38, relativeTo: .largeTitle))
                .foregroundStyle(Color.appPrimaryText)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 16)

            Button { isArrangementSheetPresented = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.pressOpacity)
            .accessibilityLabel("Arrange Library")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var formatFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFormatFilter.allCases) { filter in
                    Button {
                        formatFilterRawValue = filter.rawValue
                    } label: {
                        Text(filter.title)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(
                                filter == formatFilter ? Color.appBackground : Color.appPrimaryText)
                            .padding(.horizontal, 17)
                            .frame(height: 38)
                            .background(
                                filter == formatFilter
                                    ? Color.appPrimaryText
                                    : Color.appSecondaryBackground,
                                in: Capsule())
                    }
                    .buttonStyle(.pressOpacity)
                    .accessibilityAddTraits(filter == formatFilter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .accessibilityLabel("Library format filters")
    }

    @ViewBuilder
    private var libraryContent: some View {
        if viewModel.savedGenerations.isEmpty {
            emptyState
        } else if sortedGenerations.isEmpty {
            filteredEmptyState
        } else {
            List {
                switch layoutMode {
                case .list:
                    ForEach(sortedGenerations) { generation in
                        libraryRow(for: generation)
                    }

                case .grouped:
                    ForEach(groupedGenerations) { section in
                        Section {
                            ForEach(section.generations) { generation in
                                libraryRow(for: generation)
                            }
                        } header: {
                            Text(section.key.title)
                                .font(AppTextStyle.sectionTitle.font)
                                .foregroundStyle(Color.appPrimaryText)
                                .textCase(nil)
                                .padding(.top, 14)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            // Keep the final book reachable above the persistent mini player
            // and custom tab chrome, even when the root inset is changing.
            .contentMargins(.bottom, 112, for: .scrollContent)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.appSecondaryText)
            Text("No books yet")
                .font(AppTextStyle.body.font)
                .foregroundStyle(Color.appPrimaryText)
            Text("Books you import or write will appear here.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Text("No \(formatFilter.title) books")
                .font(AppTextStyle.body.font)
                .foregroundStyle(Color.appPrimaryText)
            Text("Try another format filter.")
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tapping a row's own "•••" slides its content left to reveal
    /// Edit/Delete underneath — replaced `.swipeActions` (a drag gesture)
    /// since the ask was specifically a tap-driven reveal. `isRevealed`
    /// lives on `revealedGenerationID` up in `LibraryTabView`, not locally
    /// on the row, so opening one row's actions closes any other row's.
    private func libraryRow(for generation: SavedGenerationSummary) -> some View {
        let isRevealed = revealedGenerationID == generation.id
        return ZStack(alignment: .trailing) {
            LibraryRowActions(
                title: generation.title,
                onEdit: {},
                onDelete: {
                    viewModel.delete(generation)
                    if revealedGenerationID == generation.id { revealedGenerationID = nil }
                })

            LibraryBookRow(
                generation: generation,
                onOpen: {
                    // A tap anywhere on a row while a *different* row is open
                    // closes that other row first, rather than acting on
                    // this one immediately — matches the native swipe-row
                    // convention this replaced.
                    if let revealedGenerationID, revealedGenerationID != generation.id {
                        self.revealedGenerationID = nil
                    } else {
                        open(generation)
                    }
                },
                onToggleReveal: {
                    revealedGenerationID = isRevealed ? nil : generation.id
                })
                .background(Color.appBackground)
                .offset(x: isRevealed ? -LibraryRowActions.width : 0)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isRevealed)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
        .accessibilityLabel(
            "\(generation.title), \(Int((generation.readingProgress * 100).rounded())) percent read")
    }

    private var sortOrderBinding: Binding<LibrarySortOrder> {
        Binding(
            get: { sortOrder },
            set: { sortOrderRawValue = $0.rawValue })
    }

    private var layoutModeBinding: Binding<LibraryLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeRawValue = $0.rawValue })
    }

    private func isInDisplayOrder(
        _ lhs: SavedGenerationSummary,
        _ rhs: SavedGenerationSummary
    ) -> Bool {
        switch sortOrder {
        case .recent:
            return lhs.createdAt > rhs.createdAt
        case .alphabetical:
            let comparison = lhs.title.localizedStandardCompare(rhs.title)
            return comparison == .orderedSame
                ? lhs.createdAt > rhs.createdAt
                : comparison == .orderedAscending
        }
    }

    private func open(_ generation: SavedGenerationSummary) {
        guard let project = viewModel.project(for: generation.id) else { return }
        onOpenProject(project)
    }
}

private struct LibraryBookRow: View {
    let generation: SavedGenerationSummary
    let onOpen: () -> Void
    let onToggleReveal: () -> Void

    private var percent: Int {
        Int((generation.readingProgress * 100).rounded())
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                SavedProjectCover(
                    coverURL: generation.coverURL,
                    title: generation.title,
                    size: CGSize(width: 50, height: 74),
                    cornerRadius: 8)

                VStack(alignment: .leading, spacing: 4) {
                    Text(generation.title)
                        .font(AppTextStyle.rowTitle.font)
                        .foregroundStyle(Color.appPrimaryText)
                        .lineLimit(1)

                    Text(
                        "\(percent)% · \(Self.dateFormatter.string(from: generation.createdAt)) · "
                            + generation.source.libraryFormatLabel.lowercased()
                    )
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .frame(height: 74)
            // Reserves room for the "•••" button overlaid below — an
            // overlay doesn't expand this HStack's own reported width, so
            // without this a long title could truncate right up against it
            // instead of stopping short to leave it clear.
            .padding(.trailing, 40)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A `Button` layered via `.overlay` on another `Button` is hit-tested
        // above it — the same escape this app's Stats summary card pencil
        // uses — rather than nesting it inside this Button's own label,
        // where the outer Button would swallow its taps.
        .overlay(alignment: .trailing) {
            Button(action: onToggleReveal) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.appTertiaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressOpacity)
            .accessibilityLabel("More options for \(generation.title)")
        }
    }
}

/// The Edit/Delete pair a row's "•••" slides into view. Fixed width shared
/// with the row's own slide offset in `LibraryTabView.libraryRow(for:)`, so
/// the two stay in sync by construction rather than two separately-tuned
/// numbers.
private struct LibraryRowActions: View {
    static let width: CGFloat = 136

    let title: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                systemName: "pencil", label: "Edit",
                background: Color.tabInactiveDark.opacity(0.35), action: onEdit)
                .accessibilityLabel("Edit \(title), coming soon")

            actionButton(
                systemName: "trash", label: "Delete",
                background: Color.red, action: onDelete)
                .accessibilityLabel("Delete \(title)")
        }
        .frame(width: Self.width, height: 74)
        .padding(.vertical, 3)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func actionButton(
        systemName: String, label: String, background: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background)
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryGenerationSection: Identifiable {
    let key: LibraryGenerationSectionKey
    let generations: [SavedGenerationSummary]
    let mostRecentDate: Date

    var id: String { key.id }
}

private enum LibraryGenerationSectionKey: Hashable {
    case today
    case yesterday
    case month(Date)

    init(date: Date, calendar: Calendar) {
        if calendar.isDateInToday(date) {
            self = .today
        } else if calendar.isDateInYesterday(date) {
            self = .yesterday
        } else {
            let components = calendar.dateComponents([.year, .month], from: date)
            self = .month(calendar.date(from: components) ?? date)
        }
    }

    var id: String {
        switch self {
        case .today: "today"
        case .yesterday: "yesterday"
        case let .month(date): "month-\(date.timeIntervalSinceReferenceDate)"
        }
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case let .month(date): date.formatted(.dateTime.month(.wide).year())
        }
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NavigationStack {
        LibraryTabView(viewModel: app.library, onOpenProject: { _ in })
    }
    .preferredColorScheme(.dark)
}
