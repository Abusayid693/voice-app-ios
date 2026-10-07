import SwiftUI

/// Feature-local display controls for Library. The selected values persist in
/// the tab root; this sheet only edits the bindings it receives.
struct LibraryArrangementSheet: View {
    @Binding var sortOrder: LibrarySortOrder
    @Binding var layoutMode: LibraryLayoutMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            TexturedDarkBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                optionSection("Sort") {
                    optionRow(
                        title: LibrarySortOrder.recent.title,
                        systemImage: "clock.arrow.circlepath",
                        isSelected: sortOrder == .recent
                    ) {
                        sortOrder = .recent
                    }

                    optionRow(
                        title: LibrarySortOrder.alphabetical.title,
                        systemImage: "textformat.abc",
                        isSelected: sortOrder == .alphabetical
                    ) {
                        sortOrder = .alphabetical
                    }
                }

                optionSection("View") {
                    optionRow(
                        title: LibraryLayoutMode.list.title,
                        systemImage: "list.bullet",
                        isSelected: layoutMode == .list
                    ) {
                        layoutMode = .list
                    }

                    optionRow(
                        title: LibraryLayoutMode.grouped.title,
                        systemImage: "square.grid.2x2",
                        isSelected: layoutMode == .grouped
                    ) {
                        layoutMode = .grouped
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 72)

            header
        }
        .presentationBackground(.clear)
        .presentationDetents([.height(350)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        ZStack {
            ProgressiveHeaderBlur()

            HStack {
                Text("Arrange Library")
                    .font(.custom("EBGaramond-Italic", size: 30, relativeTo: .title2))
                    .fontWeight(.medium)
                    .foregroundStyle(Color.appPrimaryText)

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.appPrimaryText)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.pressOpacity)
                .frame(width: 44, height: 44)
                .accessibilityLabel("Close arrangement options")
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 60, alignment: .top)
    }

    private func optionSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)

            VStack(spacing: 2) {
                content()
            }
            .padding(4)
            .background(Color.appSecondaryBackground.opacity(0.86), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func optionRow(
        title: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 24)

                Text(title)
                    .font(AppTextStyle.rowTitle.font)

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appSecondaryText)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(
                isSelected ? Color.appPrimaryText.opacity(0.10) : .clear,
                in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.pressOpacity)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    Text("Library")
        .sheet(isPresented: .constant(true)) {
            LibraryArrangementSheet(
                sortOrder: .constant(.recent),
                layoutMode: .constant(.grouped))
        }
}
