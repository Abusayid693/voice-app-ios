import SwiftUI

/// Voice discovery, pushed onto Home's stack from the Explore menu (the type
/// name is historical — it was a peer tab before). A browse/preview surface
/// only: it lost its cloned-voice creation and "Your voices" list when voice
/// cloning and Pocket TTS were removed, leaving the Kokoro catalogue.
/// Preview metering stays localized to each card rather than invalidating
/// this whole view.
struct VoicesTabView: View {
    @ObservedObject var packs: VoicePackStore
    let app: AppEnvironment

    @State private var selectedVoiceTile: VoiceTile?

    var body: some View {
        List {
            ForEach(KokoroVariant.allCases) { variant in
                Section(variant.displayName) {
                    voiceGrid(for: variant)
                }
                .listRowBackground(Color.appBackground)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
        }
        // Default `List` styling is `.insetGrouped` here (no other
        // `.listStyle` call in this app overrides it) — that adds a side
        // margin and rounded corners at the *section* level, separate from
        // `.listRowInsets`, which only zeroes a row's own internal padding.
        // The zeroed row insets alone still left each horizontal grid
        // inset from the true screen edges; `.plain` removes the section
        // margin so the grids can actually reach edge-to-edge.
        .listStyle(.plain)
        .contentMargins(.top, 8, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Voices")
        // This page is pushed onto Home's own NavigationStack, whose
        // *default* nav bar chrome is light (Home/Book Shelf is the app's
        // one light screen) — `.environment(\.colorScheme, .dark)` at the
        // push site (ImportHomeView) recolors this page's own SwiftUI
        // content, but the nav bar itself is UIKit-bridged chrome that
        // doesn't read `.environment`, only `.preferredColorScheme`/
        // `.toolbarColorScheme`. Stating it here directly, rather than
        // relying solely on Home's window-level `.preferredColorScheme`
        // toggle, is what actually guarantees a white title.
        // `.toolbarBackground(.visible, ...)` pairs with it — without an
        // explicit background visibility, some iOS versions don't fully
        // materialize a custom `.toolbarColorScheme` on the bar.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .sheet(item: $selectedVoiceTile) { tile in
            VoicePreviewSheet(
                tiles: voiceTiles,
                initialTileID: tile.id,
                previewPlayer: app.previewPlayer)
        }
    }

    private var voiceTiles: [VoiceTile] {
        KokoroVariant.allCases.flatMap(tiles(for:))
    }

    private func tiles(for variant: KokoroVariant) -> [VoiceTile] {
        VoiceCatalog.voices(for: variant).map { voice in
            VoiceTile(
                id: "kokoro-\(variant.rawValue)-\(voice.code)",
                voice: voice,
                engine: .kokoroAne,
                engineLabel: variant == .english
                    ? "Kokoro-ANE"
                    : "Kokoro-ANE (\(variant.displayName))",
                isAvailable: packs.isKokoroPackReady(variant))
        }
    }

    private func voiceGrid(for variant: KokoroVariant) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(
                rows: [
                    GridItem(.fixed(60), spacing: 14),
                    GridItem(.fixed(60), spacing: 16),
                ],
                spacing: 0
            ) {
                ForEach(tiles(for: variant)) { tile in
                    PreviewVoiceCard(tile: tile, previewPlayer: app.previewPlayer) {
                        selectedVoiceTile = tile
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        // Explicit, like every other ScrollView nested in a List row here —
        // without one the row can report an ambiguous intrinsic height and
        // cut the List's own scrolling short of its last section.
        .frame(height: 150)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NavigationStack {
        VoicesTabView(packs: app.tts.packs, app: app)
    }
    .preferredColorScheme(.dark)
}
