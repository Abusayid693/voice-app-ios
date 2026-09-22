import SwiftUI

/// A memory-bounded table of contents for reader pages. Rows load and retain
/// only their short previews, never the complete set of page bodies.
struct ReaderPagePickerSheet: View {
    let project: SavedGeneration
    let library: LibraryViewModel
    let currentPageIndex: Int
    let theme: ReaderTheme
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var previews: [Int: ReaderPagePreview] = [:]

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(0..<project.pageCount, id: \.self) { index in
                        pageRow(index: index)
                            .onAppear { loadPreview(for: index) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 70)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)

            header
                .background(.ultraThinMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .presentationBackground(.clear)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
        .presentationContentInteraction(.scrolls)
        .preferredColorScheme(theme.colorScheme)
    }

    private var header: some View {
        ZStack {
            Text("Pages")
                .font(AppTextStyle.rowTitle.font)
                .foregroundStyle(theme.primaryText)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.optionsAccent)
                        .frame(width: 36, height: 36)
                        .background(
                            theme.primaryText.opacity(theme.colorScheme == .dark ? 0.12 : 0.07),
                            in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close page picker")

                Spacer()
            }
        }
        .frame(height: 54)
        .padding(.horizontal, 10)
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
        .accessibilityLabel("\(preview?.excerpt ?? "Page"), page \(index + 1)")
        .accessibilityAddTraits(isCurrentPage ? .isSelected : [])
    }

    private func loadPreview(for index: Int) {
        guard previews[index] == nil else { return }
        previews[index] = library.pagePreview(for: project, index: index)
    }
}
