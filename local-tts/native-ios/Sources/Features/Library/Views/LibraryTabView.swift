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
                .font(.custom("EBGaramond-Italic", size: 48, relativeTo: .largeTitle))
                .fontWeight(.medium)
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
                                    : Color.appSecondaryBackground.opacity(0.88),
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

    private func libraryRow(for generation: SavedGenerationSummary) -> some View {
        Button { open(generation) } label: {
            LibraryBookRow(generation: generation)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {} label: {
                Image(systemName: "pencil")
            }
            .tint(Color.tabInactiveDark)
            .accessibilityLabel("Edit \(generation.title), coming soon")

            Button(role: .destructive) {
                viewModel.delete(generation)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Delete \(generation.title)")
        }
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

    private var percent: Int {
        Int((generation.readingProgress * 100).rounded())
    }

    var body: some View {
        HStack(spacing: 14) {
            SavedProjectCover(
                coverURL: generation.coverURL,
                title: generation.title,
                size: CGSize(width: 50, height: 74),
                cornerRadius: 5)

            VStack(alignment: .leading, spacing: 0) {
                Text(generation.title)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(generation.source.libraryFormatLabel) · \(generation.pageCountLabel)")
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(Color.appSecondaryText)
                        .lineLimit(1)

                    HStack(spacing: 7) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.appPrimaryText.opacity(0.16))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.appPrimaryText)
                                        .frame(width: proxy.size.width * generation.readingProgress)
                                }
                        }
                        .frame(width: 100, height: 3)

                        Text("\(percent)%")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.appSecondaryText)
                    }
                }
            }
            .frame(height: 74)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
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
