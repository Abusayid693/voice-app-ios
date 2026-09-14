import LucideSwift
import SwiftUI

/// Reports whether a ScrollView is parked at (or within `threshold` of) its
/// top, so ImportHomeView can fade the Setup pointer out as soon as the user
/// scrolls away from it.
///
/// Uses `.onScrollGeometryChange` rather than the older
/// GeometryReader-in-the-content's-`.background` + PreferenceKey recipe. That
/// recipe silently stopped working: modern ScrollView doesn't re-evaluate a
/// background GeometryReader on every scroll tick, so the preference never
/// fired and the "at top" flag was stuck at `true` forever no matter which
/// coordinate space it measured against.
private struct ScrolledToTopObserver: ViewModifier {
    @Binding var isAtTop: Bool
    var threshold: CGFloat = 10

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geometry in
            // At rest contentOffset.y == -contentInsets.top (the nav bar
            // and large title are part of the top inset), so the sum —
            // not contentOffset alone — is the real distance scrolled.
            geometry.contentOffset.y + geometry.contentInsets.top <= threshold
        } action: { _, atTop in
            guard atTop != isAtTop else { return }
            withAnimation(.easeInOut(duration: 0.2)) { isAtTop = atTop }
        }
    }
}

/// The app's default screen — a consumer-facing "Import" landing page
/// (redesign target: paste/upload/scan/write actions, trending demo rows,
/// a Setup entry point for the two voice packs). Only "Write text" is
/// functional today; the rest are visual placeholders per the current
/// design pass.
struct ImportHomeView: View {
    @ObservedObject var viewModel: TTSViewModel
    @ObservedObject var voiceCloneViewModel: VoiceCloneViewModel
    @ObservedObject var libraryViewModel: LibraryViewModel
    // Passed down to the tiles and the preview sheet, which observe it
    // themselves — this screen's own body doesn't read preview state, so
    // observing it here would re-render the whole page on every meter tick.
    let previewPlayer: VoicePreviewPlayer
    // Observed: this screen's tile availability and the Setup pointer both
    // read pack readiness.
    @ObservedObject var packs: VoicePackStore
    // Owned here (not TTSViewModel) — book browsing is a separate concern
    // from TTS orchestration, and outlives this view's re-renders as long
    // as the Import tab stays alive, so "See all" resumes pagination
    // instead of refetching from page 1.
    @StateObject private var trendingBooksViewModel = TrendingBooksViewModel()
    // Which voice's preview sheet is open, if any — pure navigation state
    // for this screen, not shared elsewhere, so it lives here rather than
    // on TTSViewModel.
    @State private var selectedVoiceTile: VoiceTile?
    @State private var isCreateVoicePresented = false
    @State private var voiceCloneRoute: VoiceCloneRoute?
    @State private var isSettingsPresented = false
    // Set when tapping a Kokoro entry in Projects — see playFromSavedGeneration's
    // doc comment for why "opening" a saved entry means regenerating it fresh.
    @State private var readAlongGenerationID: KokoroGeneration.ID?
    // Setup pointer only makes sense while its target is still visible at
    // the top of the screen — hide it the moment the user scrolls away
    // from the top, rather than have it float over unrelated content.
    // Driven by ScrolledToTopObserver above.
    @State private var isScrolledToTop = true

    private var isFullyDownloaded: Bool {
        packs.isKokoroPackReady && packs.isPocketPackDownloaded && packs.isSupertonic3Downloaded
            && packs.isChatterboxNanoDownloaded
    }

    var body: some View {
        // The pointer is a sibling of the *whole* NavigationStack, not a
        // layer inside it. Anything placed inside the stack is positioned
        // relative to the stack's content area, and that area moves: when
        // the large "Import" title collapses into the inline bar on scroll,
        // the content area's origin rises by the title's height, dragging
        // any inner overlay up with it (which is what made the pointer look
        // like it scrolled, then "stuck" once the collapse finished). Out
        // here the coordinate space is the screen's safe area, which never
        // changes — and that's the same space the toolbar button lives in.
        ZStack(alignment: .topTrailing) {
            navigationContent

            if !isFullyDownloaded && isScrolledToTop {
                setupPointer
                    // 40pt down clears the 44pt nav bar; 100pt in from the
                    // trailing edge lands under "Setup" rather than the cog.
                    .padding(.top, 50)
                    .padding(.trailing, 100)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var navigationContent: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    actionGrid
                    trendingVoicesSection
                    createYourOwnVoiceRow
                    readAnythingSection
                    whatsTrendingSection
                    createYourOwnBookRow
                    projectsSection
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .modifier(ScrolledToTopObserver(isAtTop: $isScrolledToTop))
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    setupButton
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    settingsButton
                }
            }
            .task { await trendingBooksViewModel.loadInitialPageIfNeeded() }
            .navigationDestination(item: $voiceCloneRoute) { route in
                switch route {
                case .instantClone:
                    InstantCloneView(viewModel: voiceCloneViewModel) { voiceCloneRoute = nil }
                case .upload:
                    UploadVoiceView(viewModel: voiceCloneViewModel) { voiceCloneRoute = nil }
                }
            }
            .navigationDestination(item: $readAlongGenerationID) { generationID in
                ReadAlongPlayerView(generationID: generationID, viewModel: viewModel)
            }
        }
        .sheet(isPresented: $viewModel.isSetupPresented) {
            SetupSheet(viewModel: viewModel, packs: packs)
        }
        .fullScreenCover(isPresented: $viewModel.isWriteTextPresented) {
            WriteTextView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel, packs: packs)
        }
        .sheet(isPresented: $isCreateVoicePresented) {
            CreateVoiceSheet { route in
                isCreateVoicePresented = false
                voiceCloneRoute = route
            }
        }
        .sheet(item: $selectedVoiceTile) { tile in
            VoicePreviewSheet(tiles: voiceTiles, initialTileID: tile.id, previewPlayer: previewPlayer)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel)
        }
    }

    private var setupButton: some View {
        Button {
            viewModel.isSetupPresented = true
        } label: {
            Label(
                title: { Text("Setup") },
                icon: {
                    LucideIcon(isFullyDownloaded ? .circleCheck : .circleArrowDown)
                })
        }
    }

    // Floats in screen space outside the NavigationStack (see body) so it
    // stays pinned under the Setup toolbar button no matter how far the
    // page scrolls or whether the large title has collapsed. Never attached
    // to the button itself — that would make it participate in the
    // toolbar's own layout and push the other item around.
    private var setupPointer: some View {
        Image("SetupPointer")
            .resizable()
            .scaledToFit()
            .frame(width: 28.8, height: 48)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            LucideIcon(.cog)
        }
    }

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ImportActionCard(title: "Paste a link", icon: .link, action: {})
            ImportActionCard(title: "Upload a file", icon: .file, action: {})
            ImportActionCard(title: "Scan text", icon: .scan, action: {})
            ImportActionCard(title: "Write text", icon: .textCursor) {
                viewModel.isWriteTextPresented = true
            }
        }
    }

    // Every real voice from both packs, not just a curated few — shown
    // regardless of download state (per the request to "show all voices
    // available"); isAvailable just controls cover art vs. a gradient
    // placeholder below.
    private var voiceTiles: [VoiceTile] {
        let kokoro = KokoroVariant.allCases.flatMap { variant in
            VoiceCatalog.voices(for: variant).map { voice in
                VoiceTile(
                    id: "kokoro-\(variant.rawValue)-\(voice.code)", voice: voice, engine: .kokoroAne,
                    engineLabel: variant == .english ? "Kokoro-ANE" : "Kokoro-ANE (\(variant.displayName))",
                    isAvailable: packs.isKokoroPackReady(variant))
            }
        }
        let pocket = VoiceCatalog.pocket.map { voice in
            VoiceTile(
                id: "pocket-\(voice.code)", voice: voice, engine: .pocketTts,
                engineLabel: "Pocket TTS", isAvailable: packs.isPocketPackDownloaded)
        }
        let supertonic3 = VoiceCatalog.supertonic3.map { voice in
            VoiceTile(
                id: "supertonic3-\(voice.code)", voice: voice, engine: .supertonic3,
                engineLabel: "Supertonic-3", isAvailable: packs.isSupertonic3Downloaded)
        }
        let chatterboxNano = VoiceCatalog.chatterboxNano.map { voice in
            VoiceTile(
                id: "chatterbox-nano-\(voice.code)", voice: voice, engine: .chatterboxNano,
                engineLabel: "Chatterbox Nano", isAvailable: packs.isChatterboxNanoDownloaded)
        }
        return kokoro + pocket + supertonic3 + chatterboxNano
    }

    private var trendingVoicesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trending voices").font(.headline).foregroundStyle(Color.appPrimaryText)
            // Cancels the parent VStack's .padding(.horizontal) (default,
            // 16pt) just for this scroll view's own clipping bounds, then
            // re-adds the same 16pt as content inset — so cards still start
            // flush with the rest of the screen, but scrolling isn't
            // clipped early at that boundary; the last/first card can
            // slide all the way to the true screen edge.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: [GridItem(.fixed(84)), GridItem(.fixed(68))], spacing: 0) {
                    ForEach(voiceTiles) { tile in
                        VoiceTileView(tile: tile, previewPlayer: previewPlayer) {
                            selectedVoiceTile = tile
                        }
                    }
                }
                // Each tile becomes a snap candidate; for a 2-row grid this
                // snaps per column (both stacked tiles at that horizontal
                // offset), not per individual tile.
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
        }
    }

    // Real, unlike createYourOwnBookRow below — opens the same CreateVoiceSheet
    // (Instant Clone / Upload file) as the Voices tab's own entry point.
    private var createYourOwnVoiceRow: some View {
        Button {
            isCreateVoicePresented = true
        } label: {
            HStack(spacing: 12) {
                LucideIcon(.mic, style: .filled, size: 28, color: Color.appPrimaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create your own voice").font(.subheadline).bold()
                        .foregroundStyle(Color.appPrimaryText)
                    Text("Clone your voice in seconds").font(.caption)
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

    // "Read Anything" — a horizontally scrolling row of promo cards, one
    // card per item so more can be appended later. Card width/image size
    // are fixed per the supplied design (327x188 image, full card width
    // 327), not derived from screen width.
    private var readAnythingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read Anything").font(.headline).foregroundStyle(Color.appPrimaryText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(readAnythingItems) { item in
                        ReadAnythingCard(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
        }
    }

    // Curated, hand-picked covers (issue: replace the live Gutendex preview
    // row with 5 specific books) — "See all" still opens the live,
    // paginated Gutendex feed unchanged, so this row is a curated
    // highlight, not the app's only source of trending books.
    private var whatsTrendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What's trending").font(.headline).foregroundStyle(Color.appPrimaryText)
                Spacer()
                NavigationLink {
                    AllTrendingBooksView(viewModel: trendingBooksViewModel)
                } label: {
                    Text("See all")
                        .font(.subheadline)
                        .foregroundStyle(Color.appSecondaryText)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(curatedTrendingBooks) { book in
                        TrendingBookCard(book: book, coverSize: curatedCoverWidth, coverHeight: curatedCoverHeight)
                    }
                }
            }
        }
    }

    private var createYourOwnBookRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                LucideIcon(.circlePlus, size: 28, color: Color.appPrimaryText)
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

    // Real generations (latest 5, newest first) once any exist; falls back
    // to the static demo row + a "Create your own project" entry point
    // (no action yet, matching createYourOwnBookRow's own no-op) while the
    // library is still empty.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects").font(.headline).foregroundStyle(Color.appPrimaryText)
            if libraryViewModel.savedGenerations.isEmpty {
                ForEach(DemoContent.projects) { project in
                    projectRow(title: project.title, subtitle: project.subtitle, updatedLabel: project.updatedLabel)
                }
                createYourOwnProjectRow
            } else {
                ForEach(libraryViewModel.savedGenerations.prefix(5)) { generation in
                    projectRow(
                        title: VoiceDisplayName.forCode(generation.voiceName),
                        subtitle: generation.text,
                        updatedLabel: "Updated \(generation.createdAt.formatted(date: .abbreviated, time: .omitted))"
                    )
                    // Kokoro only — plays the saved audio straight from
                    // disk when available (LibraryPlayback), regenerating
                    // only as a fallback; there's no Pocket player yet.
                    .onTapGesture {
                        guard generation.engine == .kokoroAne else { return }
                        if let newID = LibraryPlayback.open(
                            generation, ttsViewModel: viewModel, libraryViewModel: libraryViewModel)
                        {
                            readAlongGenerationID = newID
                        }
                    }
                }
            }
        }
    }

    private func projectRow(title: String, subtitle: String, updatedLabel: String) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.appSecondaryBackground)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold().foregroundStyle(Color.appPrimaryText)
                Text(subtitle).font(.caption).foregroundStyle(Color.appSecondaryText)
                    .lineLimit(1)
                Text(updatedLabel).font(.caption2).foregroundStyle(Color.appTertiaryText)
            }
            Spacer()
            LucideIcon(.circlePlay, size: 22, color: Color.appPrimaryText)
        }
        .contentShape(Rectangle())
    }

    private var createYourOwnProjectRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                LucideIcon(.circlePlus, size: 28, color: Color.appPrimaryText)
                Text("Create your own project").font(.subheadline).bold()
                    .foregroundStyle(Color.appPrimaryText)
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Hand-curated covers for `whatsTrendingSection`'s preview row — real
/// public-domain titles, custom-generated cover art (`assets/cover/`),
/// bundled locally rather than fetched. `id`s are negative, real Gutendex
/// ids are always positive, so there's no collision if a curated title ever
/// also appears in the live "See all" feed.
///
/// All 5 source images share the same real 2:3 portrait aspect (checked
/// directly: 1152x1728px) — sized here at that exact proportion so the
/// whole cover shows uncropped, rather than `TrendingBookCard`'s usual
/// square crop (which fits "See all"'s real, aspect-varying Gutendex
/// covers, but would cut these off).
private let curatedCoverWidth: CGFloat = 179
private let curatedCoverHeight: CGFloat = curatedCoverWidth * 1728 / 1152

private let curatedTrendingBooks: [TrendingBook] = [
    TrendingBook(
        id: -1, title: "Pride and Prejudice", authorName: "Jane Austen", coverURL: nil,
        downloadCount: 0, localCoverAssetName: "BookCoverPrideAndPrejudice"),
    TrendingBook(
        id: -2, title: "Sense and Sensibility", authorName: "Jane Austen", coverURL: nil,
        downloadCount: 0, localCoverAssetName: "BookCoverSenseAndSensibility"),
    TrendingBook(
        id: -3, title: "The Odyssey", authorName: "Homer", coverURL: nil,
        downloadCount: 0, localCoverAssetName: "BookCoverTheOdyssey"),
    TrendingBook(
        id: -4, title: "Moby-Dick", authorName: "Herman Melville", coverURL: nil,
        downloadCount: 0, localCoverAssetName: "BookCoverMobyDick"),
    TrendingBook(
        id: -5, title: "Frankenstein", authorName: "Mary Shelley", coverURL: nil,
        downloadCount: 0, localCoverAssetName: "BookCoverFrankenstein"),
]

/// Static content for `readAnythingSection` — just one card today; append
/// more here as they're designed, `ReadAnythingCard`/the section's
/// ForEach need no changes to pick them up.
private let readAnythingItems: [ReadAnythingItem] = [
    ReadAnythingItem(
        id: "sample",
        imageName: "ReadAnythingSample",
        title: "Turn any book into audio",
        description: "Pick up where you left off, hands-free — listen to your library anywhere."),
    ReadAnythingItem(
        id: "sample2",
        imageName: "ReadAnythingSample2",
        title: "Hear it before you commit",
        description: "A real 30-minute demo, generated right on iPhone — no cloud round-trip.",
        showsPlayButton: true),
]

private struct ReadAnythingItem: Identifiable {
    let id: String
    let imageName: String
    let title: String
    let description: String
    // Decorative only today — not wired to real playback, since these
    // cards have no associated audio yet.
    var showsPlayButton: Bool = false
}

/// One "Read Anything" promo card: a fixed-size 327x188 image on top, title
/// + short description below. Card width is fixed at 327 (not derived from
/// screen width) per the supplied design.
private struct ReadAnythingCard: View {
    let item: ReadAnythingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(item.imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 327, height: 188)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(alignment: .leading) {
                    if item.showsPlayButton {
                        LucideIcon(.circlePlay, size: 36, color: Color(hex: 0xD5AB80))
                            .padding(.leading, 29)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                CardTitle(text: item.title)
                CardDesc(text: item.description)
                    .lineLimit(2)
            }
        }
        .frame(width: 327, alignment: .leading)
    }
}

private struct ImportActionCard: View {
    let title: String
    let icon: LucideIconName
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                LucideIcon(icon, size: 20, color: Color.appPrimaryText)
                Text(title)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(Color.appPrimaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 80)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
        }
        .buttonStyle(.plain)
    }
}

/// A voice plus the per-screen context the catalog doesn't own: which
/// engine will speak it, and whether its pack is downloaded yet.
struct VoiceTile: Identifiable {
    let id: String
    let voice: Voice
    let engine: Engine
    let engineLabel: String
    let isAvailable: Bool

    /// Raw code passed to the engine (e.g. "af_alloy", "bill_boerst").
    var name: String { voice.code }
    var displayName: String { voice.displayName }
    var countryFlag: String { voice.flag }

    // Falls back to the engine label for voices with no persona written
    // yet (all of Pocket TTS and Japanese today).
    var descriptionText: String { voice.tagline ?? engineLabel }
    var longDescription: String {
        voice.longDescription ?? "A distinctive voice with its own character."
    }
}

/// One row per voice: cover image, name, a short persona tagline, and a
/// trailing play/pause indicator (reflects whether this voice's preview is
/// the one currently playing, started from VoicePreviewSheet). The whole
/// card is the tap target — tapping opens VoicePreviewSheet.
private struct VoiceTileView: View {
    let tile: VoiceTile
    @ObservedObject var previewPlayer: VoicePreviewPlayer
    let onTap: () -> Void

    private var isPreviewing: Bool { previewPlayer.playingVoiceID == tile.name }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                avatar
                    .frame(width: 60, height: 60)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 5) {
                    CardTitle(text: tile.displayName)
                        .lineLimit(1)
                    CardDesc(text: tile.descriptionText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                LucideIcon(isPreviewing ? .circlePause : .circlePlay, size: 22, color: Color.appTertiaryText)
            }
            .padding(.horizontal, 14)
            .frame(width: 268, height: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tile.isAvailable)
        .opacity(tile.isAvailable ? 1 : 0.6)
    }

    private var avatar: some View {
        Image(VoiceCoverArt.assetName(for: tile.name))
            .resizable()
            .scaledToFill()
    }
}

#Preview {
    let dependencies = DependencyContainer()
    let viewModel = TTSViewModel(dependencies: dependencies)
    ImportHomeView(
        viewModel: viewModel,
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel(), previewPlayer: VoicePreviewPlayer(),
        packs: viewModel.packs)
}
