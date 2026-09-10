import SwiftUI

/// The app's default screen — a consumer-facing "Import" landing page
/// (redesign target: paste/upload/scan/write actions, trending demo rows,
/// a Setup entry point for the two voice packs). Only "Write text" is
/// functional today; the rest are visual placeholders per the current
/// design pass.
struct ImportHomeView: View {
    @ObservedObject var viewModel: TTSViewModel

    private var isFullyDownloaded: Bool {
        viewModel.isKokoroPackReady && viewModel.isPocketPackDownloaded
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    actionGrid
                    trendingVoicesSection
                    whatsTrendingSection
                    createYourOwnBookRow
                    projectsSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Import")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    setupButton
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $viewModel.isSetupPresented) {
            SetupSheet(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isWriteTextPresented) {
            WriteTextView(viewModel: viewModel)
        }
    }

    private var setupButton: some View {
        Button {
            viewModel.isSetupPresented = true
        } label: {
            Label("Setup", systemImage: isFullyDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ImportActionCard(title: "Paste a link", systemImage: "link", action: {})
            ImportActionCard(title: "Upload a file", systemImage: "doc", action: {})
            ImportActionCard(title: "Scan text", systemImage: "viewfinder", action: {})
            ImportActionCard(title: "Write text", systemImage: "character.cursor.ibeam") {
                viewModel.isWriteTextPresented = true
            }
        }
    }

    // Every real voice from both packs, not just a curated few — shown
    // regardless of download state (per the request to "show all voices
    // available"); isAvailable just controls cover art vs. a gradient
    // placeholder below.
    private var voiceTiles: [VoiceTile] {
        TTSViewModel.kokoroVoices.map {
            VoiceTile(id: "kokoro-\($0)", name: $0, engineLabel: "Kokoro-ANE", isAvailable: viewModel.isKokoroPackReady)
        } + TTSViewModel.pocketVoices.map {
            VoiceTile(id: "pocket-\($0)", name: $0, engineLabel: "Pocket TTS", isAvailable: viewModel.isPocketPackDownloaded)
        }
    }

    private var trendingVoicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trending voices").font(.headline).foregroundStyle(Color.appPrimaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(64)), GridItem(.fixed(64))], spacing: 12) {
                    ForEach(voiceTiles) { tile in
                        VoiceTileView(tile: tile)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var whatsTrendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What's trending").font(.headline).foregroundStyle(Color.appPrimaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(DemoContent.trendingBooks) { book in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(book.tint.gradient)
                                .frame(width: 110, height: 150)
                                .overlay {
                                    Image(systemName: "book.closed.fill")
                                        .font(.title)
                                        .foregroundStyle(.white.opacity(0.85))
                                }
                            Text(book.title).font(.caption).bold().foregroundStyle(Color.appPrimaryText)
                                .lineLimit(1)
                            Text(book.subtitle).font(.caption2).foregroundStyle(Color.appSecondaryText)
                                .lineLimit(1)
                        }
                        .frame(width: 110)
                    }
                }
            }
        }
    }

    private var createYourOwnBookRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title)
                    .foregroundStyle(Color.appPrimaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your own book").font(.subheadline).bold()
                        .foregroundStyle(Color.appPrimaryText)
                    Text("Craft your own story in seconds").font(.caption)
                        .foregroundStyle(Color.appSecondaryText)
                }
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects").font(.headline).foregroundStyle(Color.appPrimaryText)
            ForEach(DemoContent.projects) { project in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color.appSecondaryBackground)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title).font(.subheadline).bold().foregroundStyle(Color.appPrimaryText)
                        Text(project.subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
                            .lineLimit(1)
                        Text(project.updatedLabel).font(.caption2).foregroundStyle(Color.appTertiaryText)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill").font(.title2)
                        .foregroundStyle(Color.appPrimaryText)
                }
                .contentShape(Rectangle())
            }
        }
    }
}

private struct ImportActionCard: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.appPrimaryText)
                Text(title)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(Color.appPrimaryText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 80)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
        }
        .buttonStyle(.plain)
    }
}

private struct VoiceTile: Identifiable {
    let id: String
    let name: String
    let engineLabel: String
    let isAvailable: Bool
}

/// One row per voice: cover image, name + engine label, play button at the
/// trailing end — mirrors the mockup's trending-voice row layout.
private struct VoiceTileView: View {
    let tile: VoiceTile

    var body: some View {
        HStack(spacing: 10) {
            avatar
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(tile.name)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(Color.appPrimaryText)
                    .lineLimit(1)
                Text(tile.engineLabel)
                    .font(.caption2)
                    .foregroundStyle(Color.appTertiaryText)
            }

            Spacer(minLength: 8)

            Image(systemName: "play.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.appPrimaryText)
        }
        .padding(.horizontal, 10)
        .frame(width: 220, height: 56)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.appSecondaryBackground))
        .opacity(tile.isAvailable ? 1 : 0.6)
    }

    @ViewBuilder
    private var avatar: some View {
        if tile.isAvailable {
            Image(VoiceCoverArt.assetName(for: tile.name))
                .resizable()
                .scaledToFill()
        } else {
            VoiceCoverArt.placeholderGradient(for: tile.name)
        }
    }
}

/// Voice avatars: a real cover image (cycled from the 5 bundled
/// `VoiceCoverN` assets) for voices whose pack is downloaded, or a
/// gradient placeholder — picked deterministically from the voice's name,
/// not re-randomized on every redraw — for voices that aren't available yet.
private enum VoiceCoverArt {
    private static let assetNames = [
        "VoiceCover1", "VoiceCover2", "VoiceCover3", "VoiceCover4", "VoiceCover5", "VoiceCover6",
    ]

    private static let gradientPairs: [[Color]] = [
        [.pink, .purple], [.blue, .teal], [.orange, .red],
        [.green, .mint], [.indigo, .cyan], [.yellow, .orange],
    ]

    static func assetName(for voiceName: String) -> String {
        assetNames[stableIndex(for: voiceName, count: assetNames.count)]
    }

    static func placeholderGradient(for voiceName: String) -> LinearGradient {
        let pair = gradientPairs[stableIndex(for: voiceName, count: gradientPairs.count)]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func stableIndex(for voiceName: String, count: Int) -> Int {
        let sum = voiceName.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return sum % count
    }
}

#Preview {
    ImportHomeView(viewModel: TTSViewModel(dependencies: DependencyContainer()))
}
