import Foundation
import SwiftUI

/// Library tab root. Filtering and arrangement are local presentation state;
/// project opening, renaming, archiving and deletion stay delegated to the
/// shared library model.
struct LibraryTabView: View {
    @ObservedObject var viewModel: LibraryViewModel
    let onOpenProject: (SavedGeneration) -> Void
    /// Separate from `onOpenProject` rather than widening its signature —
    /// mirrors `ImportHomeView`'s existing `onOpenBook`/`onListen` pair, and
    /// keeps `ReaderRoute`/`ReaderSurfaceMode` out of this feature's
    /// vocabulary entirely.
    let onListenToProject: (SavedGeneration) -> Void
    /// This project just became unplayable — archived out of sight, or
    /// deleted. A closure rather than the player itself: Library only needs
    /// to *announce* it, and holding `BookAudioPlayer` as an `@ObservedObject`
    /// here would re-render the whole book list on every playback publish.
    let onProjectUnavailable: (UUID) -> Void

    @AppStorage("library.formatFilter") private var formatFilterRawValue = LibraryFormatFilter.all.rawValue
    @AppStorage("library.sortOrder") private var sortOrderRawValue = LibrarySortOrder.recent.rawValue
    @AppStorage("library.layoutMode") private var layoutModeRawValue = LibraryLayoutMode.grouped.rawValue
    @AppStorage("library.archiveScope") private var archiveScopeRawValue = LibraryArchiveScope.active.rawValue

    /// Every Library presentation funnels through this one `.sheet(item:)`
    /// rather than several `.sheet` modifiers — two on the same view, or
    /// mutating a presented item to a different identity in the same frame,
    /// are both classic silent-no-present failures in SwiftUI.
    @State private var activeSheet: LibrarySheet?
    /// What to do once `activeSheet` has actually finished dismissing —
    /// Rename/Listen/Delete all need the actions sheet fully gone first
    /// (pushing a reader or raising a dialog while a sheet is still
    /// animating out puts it underneath). Consumed and nil'd in
    /// `runPendingAction()` *before* acting, so a cancelled re-entry can't
    /// replay it.
    @State private var pendingAction: PendingLibraryAction?
    @State private var deleteCandidate: SavedGenerationSummary?

    private enum LibrarySheet: Identifiable {
        case arrangement
        case actions(SavedGenerationSummary)
        case rename(SavedGenerationSummary)

        var id: String {
            switch self {
            case .arrangement: return "arrangement"
            case let .actions(generation): return "actions-\(generation.id)"
            case let .rename(generation): return "rename-\(generation.id)"
            }
        }
    }

    private enum PendingLibraryAction {
        case rename(SavedGenerationSummary)
        case listen(SavedGenerationSummary)
        case confirmDelete(SavedGenerationSummary)
        case setArchived(SavedGenerationSummary, Bool)
    }

    private var formatFilter: LibraryFormatFilter {
        LibraryFormatFilter(rawValue: formatFilterRawValue) ?? .all
    }

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRawValue) ?? .recent
    }

    private var layoutMode: LibraryLayoutMode {
        LibraryLayoutMode(rawValue: layoutModeRawValue) ?? .grouped
    }

    private var archiveScope: LibraryArchiveScope {
        LibraryArchiveScope(rawValue: archiveScopeRawValue) ?? .active
    }

    private var selectedPill: LibraryFilterPill {
        archiveScope == .archived ? .archived : .format(formatFilter)
    }

    private var sortedGenerations: [SavedGenerationSummary] {
        viewModel.savedGenerations
            .filter { generation in
                switch archiveScope {
                case .archived: generation.isArchived
                case .active: !generation.isArchived && formatFilter.includes(generation.source)
                }
            }
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
                filterPills
                libraryContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $activeSheet, onDismiss: runPendingAction) { sheet in
            sheetContent(for: sheet)
        }
        .confirmationDialog(
            "Delete \u{201C}\(deleteCandidate?.title ?? "")\u{201D}?",
            isPresented: Binding(
                get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Book", role: .destructive) {
                guard let generation = deleteCandidate else { return }
                deleteCandidate = nil
                // Before the files go — `delete` removes the page bodies the
                // player streams from, so a session left running on this
                // book would read from a directory that no longer exists.
                onProjectUnavailable(generation.id)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                    viewModel.delete(generation)
                }
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: {
            Text("This removes its pages, any generated audio, and its cover. This can't be undone.")
        }
    }

    @ViewBuilder
    private func sheetContent(for sheet: LibrarySheet) -> some View {
        switch sheet {
        case .arrangement:
            LibraryArrangementSheet(
                sortOrder: sortOrderBinding,
                layoutMode: layoutModeBinding)

        case let .actions(generation):
            LibraryBookActionsSheet(
                generation: generation,
                onListen: {
                    pendingAction = .listen(generation)
                    activeSheet = nil
                },
                onEdit: {
                    pendingAction = .rename(generation)
                    activeSheet = nil
                },
                onToggleArchive: {
                    pendingAction = .setArchived(generation, !generation.isArchived)
                    activeSheet = nil
                },
                onDelete: {
                    pendingAction = .confirmDelete(generation)
                    activeSheet = nil
                })

        case let .rename(generation):
            LibraryRenameBookSheet(
                generation: generation,
                onSave: { newTitle in
                    viewModel.updateTitle(newTitle, for: generation.id)
                })
        }
    }

    /// Fires from `.sheet`'s `onDismiss`, which only runs once dismissal has
    /// actually completed — see `pendingAction`'s own doc comment for why
    /// this indirection exists at all.
    private func runPendingAction() {
        guard let action = pendingAction else { return }
        pendingAction = nil
        switch action {
        case let .rename(generation):
            activeSheet = .rename(generation)
        case let .listen(generation):
            openProject(generation, listening: true)
        case let .confirmDelete(generation):
            deleteCandidate = generation
        case let .setArchived(generation, isArchived):
            // Only on the way *in*: a book you've just put out of sight
            // shouldn't keep playing in the mini player, where tapping it
            // would open a reader for something Library and My Shelf both
            // now hide. Unarchiving breaks nothing, so it stops nothing.
            if isArchived { onProjectUnavailable(generation.id) }
            // Archiving republishes `savedGenerations`, which drops this row
            // out of `sortedGenerations` — doing that while the actions
            // sheet was still up would reflow the List behind it.
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                viewModel.updateArchived(isArchived, for: generation.id)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Library")
                .font(.custom("EBGaramond-Regular", size: 38, relativeTo: .largeTitle))
                .foregroundStyle(Color.appPrimaryText)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 16)

            Button { activeSheet = .arrangement } label: {
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

    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilterPill.allPills) { pill in
                    let isSelected = pill == selectedPill
                    Button {
                        select(pill)
                    } label: {
                        Text(pill.title)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(isSelected ? Color.appBackground : Color.appPrimaryText)
                            .padding(.horizontal, 17)
                            .frame(height: 38)
                            .background(
                                isSelected ? Color.appPrimaryText : Color.appSecondaryBackground,
                                in: Capsule())
                    }
                    .buttonStyle(.pressOpacity)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .accessibilityLabel("Library filters")
    }

    private func select(_ pill: LibraryFilterPill) {
        switch pill {
        case let .format(filter):
            formatFilterRawValue = filter.rawValue
            // Leaving a format filter chosen while Archived was selected
            // would otherwise mean two stored values disagree about what's
            // "selected" — resetting scope here keeps exactly one pill
            // selected at a time.
            archiveScopeRawValue = LibraryArchiveScope.active.rawValue
        case .archived:
            // Deliberately doesn't touch `formatFilterRawValue` — returning
            // to a format pill later restores whatever was chosen before.
            archiveScopeRawValue = LibraryArchiveScope.archived.rawValue
        }
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

    /// Covers three distinct empty reasons, not one — archiving makes "every
    /// book is hidden by the current filter" reachable in two new ways that
    /// didn't exist before (`.all` can now be empty; Archived can be empty).
    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Text(filteredEmptyTitle)
                .font(AppTextStyle.body.font)
                .foregroundStyle(Color.appPrimaryText)
            Text(filteredEmptySubtitle)
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyTitle: String {
        switch archiveScope {
        case .archived:
            return "No archived books"
        case .active:
            return formatFilter == .all ? "Everything is archived" : "No \(formatFilter.title) books"
        }
    }

    private var filteredEmptySubtitle: String {
        switch archiveScope {
        case .archived:
            return "Books you archive are hidden here until you bring them back."
        case .active:
            return formatFilter == .all
                ? "Open the Archived filter to bring a book back."
                : "Try another format filter."
        }
    }

    private func libraryRow(for generation: SavedGenerationSummary) -> some View {
        LibraryBookRow(
            generation: generation,
            onOpen: { openProject(generation, listening: false) },
            onMoreOptions: { activeSheet = .actions(generation) })
            .listRowBackground(Color.appBackground)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 7, leading: 20, bottom: 7, trailing: 20))
            // `allowsFullSwipe: false` is deliberate: Delete is declared
            // first (the trailing edge renders its *last*-declared button
            // leftmost, so first-declared lands rightmost, preserving the
            // shipped Edit | Delete order) and Library's delete is
            // unrecoverable — a full swipe must not be able to fire it.
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { deleteCandidate = generation } label: {
                    Label("Delete", systemImage: "trash")
                }
                Button { activeSheet = .rename(generation) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(Color.tabInactiveDark.opacity(0.35))
            }
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

    private func openProject(_ generation: SavedGenerationSummary, listening: Bool) {
        guard let project = viewModel.project(for: generation.id) else { return }
        if listening {
            onListenToProject(project)
        } else {
            onOpenProject(project)
        }
    }
}

private struct LibraryBookRow: View {
    let generation: SavedGenerationSummary
    let onOpen: () -> Void
    let onMoreOptions: () -> Void

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
            Button(action: onMoreOptions) {
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
        LibraryTabView(
            viewModel: app.library, onOpenProject: { _ in }, onListenToProject: { _ in },
            onProjectUnavailable: { _ in })
    }
    .preferredColorScheme(.dark)
}
