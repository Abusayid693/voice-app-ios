import SwiftUI

/// Hosted in `StandardBottomSheet` with `isTextured: true` — the same
/// `TexturedDarkBackground()` grain this sheet originated on its own custom
/// chrome, now shared with `LibraryBookActionsSheet`'s "Book Options" sheet.
/// Adopting the shared chrome means adopting its conventions too: no
/// persistent close button (drag-down dismisses, like every other
/// `StandardBottomSheet`), and the shared literal-24pt serif title in place
/// of this sheet's former bespoke 30pt EB Garamond Italic header.
struct AddCatalogSheet: View {
    let onAdd: (String, String) -> Result<CatalogSource, CatalogSourceValidationError>

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var errorMessage: String?

    var body: some View {
        StandardBottomSheet(
            title: "Add Catalog", detents: [.height(370)], showsDragIndicator: false,
            isTextured: true
        ) {
            field(title: "Name", placeholder: "My catalog", text: $name)
            field(title: "Website", placeholder: "https://example.com", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            if let errorMessage {
                Text(errorMessage)
                    .font(AppTextStyle.label.font)
                    .foregroundStyle(Color.tabSelected)
            }

            Button("Add Catalog", action: addCatalog)
                .font(AppTextStyle.rowTitle.font)
                .foregroundStyle(Color.appBackground)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Color.appPrimaryText, in: RoundedRectangle(cornerRadius: 16))
                .buttonStyle(.pressOpacity)
        }
    }

    private func field(
        title: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(AppTextStyle.label.font)
                .foregroundStyle(Color.appSecondaryText)

            TextField(placeholder, text: text)
                .font(AppTextStyle.body.font)
                .foregroundStyle(Color.appPrimaryText)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(
                    Color.appSecondaryBackground.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func addCatalog() {
        switch onAdd(name, address) {
        case .success:
            dismiss()
        case let .failure(error):
            errorMessage = error.localizedDescription
        }
    }
}
