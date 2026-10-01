import LucideSwift
import SwiftUI

/// A memory-bounded table of contents for reader pages. Rows load and retain
/// only their short previews, never the complete set of page bodies.
struct ReaderPagePickerSheet: View {
    let project: SavedGeneration
    let library: LibraryViewModel
    let currentPageIndex: Int
    let theme: ReaderTheme
    /// Distinct pages with at least one completed listen — fetched once by
    /// the presenter (ChapterPlayerView) before opening this sheet, not
    /// owned or re-fetched here.
    let completedPageIndices: Set<Int>
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previews: [Int: ReaderPagePreview] = [:]

    var body: some View {
        InteractiveGlassBottomSheet(
            theme: theme,
            detents: [.medium, .large],
            closeAccessibilityLabel: "Close page picker",
            onClose: { dismiss() }
        ) { headerInset in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<project.pageCount, id: \.self) { index in
                        pageRow(index: index)
                            .onAppear { loadPreview(for: index) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, headerInset)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func pageRow(index: Int) -> some View {
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
