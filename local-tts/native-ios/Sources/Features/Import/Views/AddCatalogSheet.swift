import SwiftUI

struct AddCatalogSheet: View {
    let onAdd: (String, String) -> Result<CatalogSource, CatalogSourceValidationError>

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var errorMessage: String?

    var body: some View {
        ZStack(alignment: .top) {
            TexturedDarkBackground()
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
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
            .padding(.horizontal, 20)
            .padding(.top, 84)

            header
        }
        .presentationBackground(.clear)
        .presentationDetents([.height(390)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        ZStack {
            ProgressiveHeaderBlur()

            HStack {
                Text("Add Catalog")
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
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 64, alignment: .top)
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
