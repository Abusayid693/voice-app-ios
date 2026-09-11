import SwiftUI

/// App settings — reached via the gear icon on Import, presented the same
/// way as SetupSheet (a plain `.sheet`, dark theme, "Done" to dismiss).
/// Voice Packs / Storage / About are placeholders for now (see issue #9,
/// which flags real prerequisites for each — pack deletion semantics,
/// storage computation, and About content — to resolve before building
/// them out); this pass wires up the entry point and navigation shell.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        SettingsPlaceholderView(title: "Voice Packs")
                    } label: {
                        row(title: "Voice Packs", systemImage: "shippingbox.fill")
                    }
                    NavigationLink {
                        SettingsPlaceholderView(title: "Storage")
                    } label: {
                        row(title: "Storage", systemImage: "internaldrive.fill")
                    }
                    NavigationLink {
                        SettingsPlaceholderView(title: "About")
                    } label: {
                        row(title: "About", systemImage: "info.circle.fill")
                    }
                }
                .listRowBackground(Color.appSecondaryBackground)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(title: String, systemImage: String) -> some View {
        Label {
            Text(title).foregroundStyle(Color.appPrimaryText)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Color.appPrimaryText)
        }
    }
}

#Preview {
    SettingsSheet()
}
