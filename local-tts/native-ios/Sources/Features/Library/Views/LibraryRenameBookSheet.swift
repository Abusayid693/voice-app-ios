import SwiftUI

/// Opened from the actions sheet's Edit row (or directly from a row's swipe
/// Edit button) to rename a book. Styled after `AddCatalogSheet`'s own
/// text-field treatment — the app's only other styled `TextField`.
struct LibraryRenameBookSheet: View {
    let generation: SavedGenerationSummary
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var isFocused: Bool

    /// 120, not the 40 `BookShelfLayoutStore.renameShelf` caps a shelf label
    /// at — a real book title (often pulled from PDF/EPUB metadata)
    /// routinely exceeds a shelf-label-sized limit. Every display site for
    /// a title is already `lineLimit(1)`, so a long one is cosmetically
    /// safe; this cap exists only to stop a pathological paste.
    private static let maxLength = 120

    init(generation: SavedGenerationSummary, onSave: @escaping (String) -> Void) {
        self.generation = generation
        self.onSave = onSave
        // Seeded here, not in `.onAppear` — seeding on appear races the
        // first render and can flash an empty field.
        _draft = State(initialValue: generation.title)
    }

    private var normalized: String {
        String(
            draft.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .prefix(Self.maxLength))
    }

    private var canSave: Bool {
        !normalized.isEmpty && normalized != generation.title
    }

    var body: some View {
        StandardBottomSheet(title: "Rename Book", detents: [.height(330)]) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Title")
                        .font(AppTextStyle.label.font)
                        .foregroundStyle(Color.appSecondaryText)

                    TextField("Book title", text: $draft)
                        .font(AppTextStyle.body.font)
                        .foregroundStyle(Color.appPrimaryText)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(
                            Color.appSecondaryBackground.opacity(0.9),
                            in: RoundedRectangle(cornerRadius: 14))
                }

                Button("Save", action: save)
                    .font(AppTextStyle.rowTitle.font)
                    .foregroundStyle(Color.appBackground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Color.appPrimaryText, in: RoundedRectangle(cornerRadius: 16))
                    .buttonStyle(.pressOpacity)
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.5)
            }
        }
        .onAppear { isFocused = true }
    }

    private func save() {
        guard canSave else { return }
        onSave(normalized)
        dismiss()
    }
}

#Preview {
    Color.appBackground
        .sheet(isPresented: .constant(true)) {
            LibraryRenameBookSheet(
                generation: SavedGenerationSummary(
                    id: UUID(), title: "The Great Gatsby", engine: .kokoroAne,
                    voiceName: "af_heart", createdAt: Date(), pageCount: 214),
                onSave: { _ in })
        }
}
