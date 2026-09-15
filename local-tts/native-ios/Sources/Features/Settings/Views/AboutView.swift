import SwiftUI

/// Settings > About — app version pulled from the real bundle
/// (CFBundleShortVersionString/CFBundleVersion), not hardcoded, so it stays
/// correct as the app is versioned going forward.
struct AboutView: View {
    private var versionLabel: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(shortVersion) (\(build))"
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Version").font(.appRowTitle).foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    Text(versionLabel).font(.appBody).foregroundStyle(Color.appSecondaryText)
                }
                HStack {
                    Text("Engines").font(.appRowTitle).foregroundStyle(Color.appPrimaryText)
                    Spacer()
                    Text("Kokoro-ANE, Pocket TTS").font(.appBody).foregroundStyle(Color.appSecondaryText)
                }
            }
            .listRowBackground(Color.appSecondaryBackground)

            Section {
                Text("On-device text-to-speech, powered by FluidAudio. No audio leaves your device.")
                    .font(.appLabel)
                    .foregroundStyle(Color.appSecondaryText)
            }
            .listRowBackground(Color.appSecondaryBackground)
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground)
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { AboutView() }
}
