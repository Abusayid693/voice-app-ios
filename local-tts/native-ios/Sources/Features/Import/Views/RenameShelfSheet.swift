import SwiftUI

/// Compact shelf-title editor using the same shared chrome and form treatment
/// as Add Catalog. Shelf persistence and validation remain owned by
/// `BookShelfLayoutStore`; this view owns only its local draft and dismissal.
struct RenameShelfSheet: View {
    let initialTitle: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @FocusState private var isFocused: Bool

    private static let maxLength = 40

    init(initialTitle: String, onSave: @escaping (String) -> Void) {
        self.initialTitle = initialTitle
        self.onSave = onSave
        _draft = State(initialValue: initialTitle)
    }

    private var normalizedTitle: String {
        String(
            draft.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .prefix(Self.maxLength))
    }

    private var canSave: Bool {
        !normalizedTitle.isEmpty && normalizedTitle != initialTitle
    }

    var body: some View {
        StandardBottomSheet(
            title: "Rename Shelf", detents: [.height(300)],
            showsDragIndicator: false, isTextured: true
        ) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Name")
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.appSecondaryText)

                TextField("Shelf name", text: $draft)
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
        .onAppear { isFocused = true }
    }

    private func save() {
        guard canSave else { return }
        onSave(normalizedTitle)
        dismiss()
    }
}

#Preview {
    Color.appBackground
        .sheet(isPresented: .constant(true)) {
            RenameShelfSheet(initialTitle: "Quiet Corners", onSave: { _ in })
        }
}
