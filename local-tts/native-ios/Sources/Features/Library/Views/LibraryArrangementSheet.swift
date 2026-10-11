import SwiftUI

/// Feature-local display controls for Library. The selected values persist in
/// the tab root; this sheet only edits the bindings it receives.
///
/// Hosted in `StandardBottomSheet` with `isTextured: true` — the same
/// surface `LibraryBookActionsSheet`'s "Book Options" sheet and
/// `AddCatalogSheet` now share, rather than this sheet's own former bespoke
/// `ZStack`/`ProgressiveHeaderBlur`/close-button chrome. Row anatomy
/// (leading icon at `width: 28`, vertical-only padding so it lines up with
/// the section label above it rather than a uniform `.padding()` pushing it
/// in further) matches "Book Options" directly; a faint inset hairline
/// separates the two rows in each section instead of each section's own
/// card background.
struct LibraryArrangementSheet: View {
    @Binding var sortOrder: LibrarySortOrder
    @Binding var layoutMode: LibraryLayoutMode

    var body: some View {
        StandardBottomSheet(
            title: "Arrange Library", detents: [.height(370)], showsDragIndicator: false,
            isTextured: true
        ) {
            optionSection("Sort") {
                optionRow(
                    title: LibrarySortOrder.recent.title,
                    systemImage: "clock.arrow.circlepath",
                    isSelected: sortOrder == .recent
                ) {
                    sortOrder = .recent
                }
                divider
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
                divider
                optionRow(
                    title: LibraryLayoutMode.grouped.title,
                    systemImage: "square.grid.2x2",
                    isSelected: layoutMode == .grouped
                ) {
                    layoutMode = .grouped
                }
            }
        }
    }

    /// Inset to start under the text, not the icon — same convention as
    /// "Book Options"' own divider, kept deliberately faint.
    private var divider: some View {
        Divider()
            .overlay(Color.appPrimaryText.opacity(0.07))
            .padding(.leading, 28 + 12)
    }

    private func optionSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)

            VStack(spacing: 0) {
                content()
            }
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
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28)

                Text(title)
                    .font(AppTextStyle.rowTitle.font)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(isSelected ? Color.appPrimaryText : Color.appSecondaryText)
            // Vertical only — see this type's own doc comment: a uniform
            // `.padding()` would push the icon in past the section label's
            // left edge, which carries no horizontal inset of its own
            // beyond the sheet's outer one.
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
