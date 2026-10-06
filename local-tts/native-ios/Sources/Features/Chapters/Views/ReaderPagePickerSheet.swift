import LucideSwift
import SwiftUI

/// A memory-bounded table of contents for reader pages. Rows load and retain
/// only their short previews, never the complete set of page bodies.
///
/// For an EPUB (`chapters` non-empty), top-level chapters render as
/// collapsible headers: collapsed by default, tapping one reveals its own
/// pages indented beneath it. A PDF (`chapters` empty) falls back to exactly
/// today's flat list — this is additive, not a redesign of that path.
struct ReaderPagePickerSheet: View {
    let project: SavedGeneration
    let library: LibraryViewModel
    let currentPageIndex: Int
    let theme: ReaderTheme
    /// Distinct pages with at least one completed listen — fetched once by
    /// the presenter (ChapterPlayerView) before opening this sheet, not
    /// owned or re-fetched here.
    let completedPageIndices: Set<Int>
    /// EPUB's table of contents, resolved to page indexes — `[]` for a PDF.
    /// Only top-level (`depth == 0`) entries become a chapter row here: a
    /// book with real subsection structure would otherwise turn this list
    /// into a full outline. Depth is still stored for when that becomes a
    /// deliberate choice rather than this sheet's default.
    let chapters: [EPUBChapter]
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previews: [Int: ReaderPagePreview] = [:]
    /// Which chapters (keyed by `startPageIndex`) are expanded. Starts
    /// empty — `.onAppear` below expands whichever chapter contains
    /// `currentPageIndex`, so opening the picker doesn't hide where you are.
    @State private var expandedStartPages: Set<Int> = []

    /// One row the sheet actually lays out — a chapter header, or a page,
    /// indented when it sits beneath an expanded chapter rather than being
    /// one of a PDF's (or an EPUB's untitled leading section's) ungrouped
    /// pages.
    private enum Row: Identifiable {
        case chapterHeader(ChapterSection)
        case page(index: Int, indented: Bool)

        var id: String {
            switch self {
            case .chapterHeader(let section): return "chapter-\(section.chapter.startPageIndex)"
            case .page(let index, _): return "page-\(index)"
            }
        }
    }

    private struct ChapterSection {
        let chapter: EPUBChapter
        let pageRange: Range<Int>
    }

    /// Depth-0 chapters, each paired with the page range it owns — from its
    /// own `startPageIndex` up to the next top-level chapter's, or the end
    /// of the book for the last one. A nested (`depth > 0`) entry has no row
    /// of its own; its pages simply fall inside its parent's expanded range.
    private var chapterSections: [ChapterSection] {
        let tops = chapters.filter { $0.depth == 0 }.sorted { $0.startPageIndex < $1.startPageIndex }
        guard !tops.isEmpty else { return [] }
        return tops.enumerated().map { index, chapter in
            let end = index + 1 < tops.count ? tops[index + 1].startPageIndex : project.pageCount
            return ChapterSection(
                chapter: chapter,
                pageRange: chapter.startPageIndex..<max(chapter.startPageIndex, end))
        }
    }

    /// Walks every page once, in order, interleaving chapter headers at the
    /// page where each one starts and that chapter's own pages immediately
    /// after it only while expanded — collapsed, they're skipped outright
    /// rather than rendered and hidden, so an unopened chapter costs nothing.
    private func rows(for sections: [ChapterSection]) -> [Row] {
        guard !sections.isEmpty else {
            return (0..<project.pageCount).map { .page(index: $0, indented: false) }
        }
        var result: [Row] = []
        var sectionIndex = 0
        var pageIndex = 0
        while pageIndex < project.pageCount {
            if sectionIndex < sections.count, sections[sectionIndex].pageRange.lowerBound == pageIndex {
                let section = sections[sectionIndex]
                result.append(.chapterHeader(section))
                if expandedStartPages.contains(section.chapter.startPageIndex) {
                    result.append(contentsOf: section.pageRange.map { .page(index: $0, indented: true) })
                }
                pageIndex = section.pageRange.upperBound
                sectionIndex += 1
            } else {
                result.append(.page(index: pageIndex, indented: false))
                pageIndex += 1
            }
        }
        return result
    }

    var body: some View {
        // Computed once per body evaluation rather than inside the ForEach,
        // which would otherwise redo this O(pageCount) walk on every row.
        let sections = chapterSections
        let allRows = rows(for: sections)

        InteractiveGlassBottomSheet(
            theme: theme,
            detents: [.large],
            closeAccessibilityLabel: "Close page picker",
            onClose: { dismiss() }
        ) { headerInset in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(allRows) { row in
                        switch row {
                        case .chapterHeader(let section):
                            chapterHeaderRow(section)
                        case .page(let index, let indented):
                            pageRow(index: index, indented: indented)
                                .onAppear { loadPreview(for: index) }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, headerInset)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            guard expandedStartPages.isEmpty else { return }
            if let containing = chapterSections.first(where: { $0.pageRange.contains(currentPageIndex) }) {
                expandedStartPages.insert(containing.chapter.startPageIndex)
            }
        }
    }

    private func chapterHeaderRow(_ section: ChapterSection) -> some View {
        let isExpanded = expandedStartPages.contains(section.chapter.startPageIndex)
        let containsCurrentPage = section.pageRange.contains(currentPageIndex)

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                if isExpanded {
                    expandedStartPages.remove(section.chapter.startPageIndex)
                } else {
                    expandedStartPages.insert(section.chapter.startPageIndex)
                }
            }
        } label: {
            HStack(spacing: 10) {
                LucideIcon(
                    .chevronRight, size: 14,
                    color: containsCurrentPage ? theme.highlightedText : theme.secondaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)

                Text(section.chapter.title)
                    .font(AppTextStyle.body.font.weight(.semibold))
                    .foregroundStyle(
                        containsCurrentPage ? theme.highlightedText : theme.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                containsCurrentPage ? theme.wordHighlightBackground : theme.controlBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.chapter.title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand")")
    }

    private func pageRow(index: Int, indented: Bool) -> some View {
        let preview = previews[index]
        let isCurrentPage = index == currentPageIndex

        return Button {
            onSelect(index)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(preview?.excerpt ?? "Loading page…")
                    .font(AppTextStyle.body.font)
                    .foregroundStyle(
                        isCurrentPage
                            ? theme.highlightedText
                            : (preview?.isBlank == true ? theme.secondaryText : theme.primaryText))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if completedPageIndices.contains(index) {
                    LucideIcon(
                        .check, size: 14,
                        color: isCurrentPage ? theme.highlightedText : theme.secondaryText)
                        .accessibilityHidden(true)
                }

                Text("\(index + 1)")
                    .font(AppTextStyle.label.font)
                    .monospacedDigit()
                    .foregroundStyle(isCurrentPage ? theme.highlightedText : theme.secondaryText)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                isCurrentPage ? theme.wordHighlightBackground : theme.controlBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isCurrentPage ? theme.optionsAccent : .clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        // Indented beneath its chapter header rather than inset via the
        // row's own padding, so the highlight/stroke background still spans
        // the sheet's full content width instead of shrinking with it.
        .padding(.leading, indented ? 20 : 0)
        .accessibilityLabel(
            "\(preview?.excerpt ?? "Page"), page \(index + 1)"
                + (completedPageIndices.contains(index) ? ", completed" : ""))
        .accessibilityAddTraits(isCurrentPage ? .isSelected : [])
    }

    private func loadPreview(for index: Int) {
        guard previews[index] == nil else { return }
        previews[index] = library.pagePreview(for: project, index: index)
    }
}
