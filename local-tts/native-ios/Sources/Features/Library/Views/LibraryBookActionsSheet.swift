import SwiftUI

/// The sheet a Library row's "•••" opens — Listen, Edit, Archive/Unarchive,
/// and an isolated destructive Delete, hosted in `StandardBottomSheet` the
/// same way `ChapterPlayerOptionsSheet` hosts its own list of actions.
///
/// A value snapshot plus four closures, not an `@ObservedObject` — every
/// action here dismisses the sheet immediately (see `LibraryTabView`'s
/// `activeSheet`/`pendingAction` pair, which owns the actual sequencing),
/// so there's nothing here that needs to stay live while the sheet is
/// closing.
struct LibraryBookActionsSheet: View {
    let generation: SavedGenerationSummary
    let onListen: () -> Void
    let onEdit: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void

    /// Content height ≈ 32 top pad + title + 24 + header row + 16 + three
    /// rows + 12 + one row + 30 bottom pad — in the family of Storage's 300
    /// / Daily Goal's 330.
    private static let detent: PresentationDetent = .height(430)

    var body: some View {
        // No drag indicator — this sheet is always at its root page (no
        // nested back-button case like `ChapterPlayerOptionsSheet`, which
        // keeps one because it's the only dismiss affordance left when
        // nested); the system drag-down still works without the visible pill.
        StandardBottomSheet(
            title: "Book Options", detents: [Self.detent], showsDragIndicator: false,
            isTextured: true
        ) {
            header

            // One 12pt-spaced `VStack` rather than two top-level children —
            // `StandardBottomSheet` spaces its direct content children at a
            // uniform 24pt, and the destructive row needs to read as
            // *closer to* quarantined-apart, not just another sibling at the
            // same rhythm as everything above it. No card background on
            // either group — plain rows, with a hairline between the three
            // grouped ones only (Delete is alone, so it has no partner to
            // separate from).
            VStack(spacing: 12) {
                VStack(spacing: 0) {
                    actionRow(
                        icon: "headphones", title: "Listen", subtitle: nil,
                        tint: Color.appPrimaryText, action: onListen)
                    divider
                    actionRow(
                        icon: "pencil", title: "Edit", subtitle: nil,
                        tint: Color.appPrimaryText, action: onEdit)
                    divider
                    actionRow(
                        icon: generation.isArchived ? "tray.and.arrow.up" : "archivebox",
                        title: generation.isArchived ? "Unarchive" : "Archive",
                        subtitle: generation.isArchived
                            ? "Brings it back to Library and My Shelf"
                            : "Hides it from Library and My Shelf",
                        tint: Color.appPrimaryText, action: onToggleArchive)
                }

                actionRow(
                    icon: "trash", title: "Delete", subtitle: nil,
                    tint: .red, action: onDelete)
            }
        }
    }

    /// Inset to start under the text, not the icon — the standard native
    /// list-separator convention (Settings, Files), kept deliberately faint.
    private var divider: some View {
        Divider()
            .overlay(Color.appPrimaryText.opacity(0.07))
            .padding(.leading, 28 + 12)
    }

    private var header: some View {
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
                    .lineLimit(2)

                Text(
                    "\(generation.source.libraryFormatLabel) · \(generation.pageCountLabel) · "
                        + "\(Int((generation.readingProgress * 100).rounded()))% read"
                )
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionRow(
        icon: String, title: String, subtitle: String?, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 28)

                if let subtitle {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppTextStyle.rowTitle.font)
                            .foregroundStyle(tint)
                        Text(subtitle)
                            .font(AppTextStyle.label.font)
                            .foregroundStyle(Color.appSecondaryText)
                    }
                } else {
                    Text(title)
                        .font(AppTextStyle.rowTitle.font)
                        .foregroundStyle(tint)
                }

                Spacer(minLength: 8)
            }
            // Vertical only — a uniform `.padding()` here would push the
            // icon in past the header's own left edge (the header has no
            // horizontal inset of its own, just the sheet's outer one), so
            // Listen's icon would sit to the right of the cover above it
            // instead of lining up with it.
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Color.appBackground
        .sheet(isPresented: .constant(true)) {
            LibraryBookActionsSheet(
                generation: SavedGenerationSummary(
                    id: UUID(), title: "The Great Gatsby", engine: .kokoroAne,
                    voiceName: "af_heart", createdAt: Date(), pageCount: 214,
                    lastReadPageIndex: 68, source: .epub),
                onListen: {}, onEdit: {}, onToggleArchive: {}, onDelete: {})
        }
}
