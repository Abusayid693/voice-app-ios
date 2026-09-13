import LucideSwift
import SwiftUI

/// Reports whether a ScrollView is parked at (or within `threshold` of) its
/// top, so ImportHomeView can fade the Setup pointer out as soon as the user
/// scrolls away from it.
///
/// Uses `.onScrollGeometryChange` (iOS 18+) rather than the older
/// GeometryReader-in-the-content's-`.background` + PreferenceKey recipe. That
/// recipe silently stopped working: modern ScrollView doesn't re-evaluate a
/// background GeometryReader on every scroll tick, so the preference never
/// fired and the "at top" flag was stuck at `true` forever no matter which
/// coordinate space it measured against.
///
/// On iOS 17 there is no equivalent API, so the pointer simply stays put
/// until the packs finish downloading — it's a decorative onboarding hint,
/// and that degradation is preferable to reinstating the broken recipe.
private struct ScrolledToTopObserver: ViewModifier {
    @Binding var isAtTop: Bool
    var threshold: CGFloat = 10

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                // At rest contentOffset.y == -contentInsets.top (the nav bar
                // and large title are part of the top inset), so the sum —
                // not contentOffset alone — is the real distance scrolled.
                geometry.contentOffset.y + geometry.contentInsets.top <= threshold
            } action: { _, atTop in
                guard atTop != isAtTop else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isAtTop = atTop }
            }
        } else {
            content
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
        viewModel.isKokoroPackReady && viewModel.isPocketPackDownloaded
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
            SetupSheet(viewModel: viewModel)
        }
        .fullScreenCover(isPresented: $viewModel.isWriteTextPresented) {
            WriteTextView(
                viewModel: viewModel, voiceCloneViewModel: voiceCloneViewModel,
                libraryViewModel: libraryViewModel)
        }
        .sheet(isPresented: $isCreateVoicePresented) {
            CreateVoiceSheet { route in
                isCreateVoicePresented = false
                voiceCloneRoute = route
            }
        }
        .sheet(item: $selectedVoiceTile) { tile in
            VoicePreviewSheet(tiles: voiceTiles, initialTileID: tile.id, viewModel: viewModel)
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
        TTSViewModel.kokoroVoices.map {
            VoiceTile(
                id: "kokoro-\($0)", name: $0, engine: .kokoroAne, engineLabel: "Kokoro-ANE",
                isAvailable: viewModel.isKokoroPackReady)
        } + TTSViewModel.mandarinVoices.map {
            VoiceTile(
                id: "kokoro-zh-\($0)", name: $0, engine: .kokoroAne, engineLabel: "Kokoro-ANE (Mandarin)",
                isAvailable: viewModel.isKokoroPackReady(.mandarin))
        } + TTSViewModel.pocketVoices.map {
            VoiceTile(
                id: "pocket-\($0)", name: $0, engine: .pocketTts, engineLabel: "Pocket TTS",
                isAvailable: viewModel.isPocketPackDownloaded)
        }
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
                        VoiceTileView(tile: tile, viewModel: viewModel) {
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

struct VoiceTile: Identifiable {
    let id: String
    // Raw voice code passed to the engine (e.g. "af_alloy", "bill_boerst") —
    // kept separate from the display name so cover-art selection stays keyed
    // off the same stable identifier regardless of how it's shown.
    let name: String
    let engine: Engine
    let engineLabel: String
    let isAvailable: Bool

    // "af_alloy" -> "Alloy", "bill_boerst" -> "Bill Boerst".
    var displayName: String { VoiceDisplayName.forCode(name) }

    // A short persona tagline ("Warm and friendly") in place of the raw
    // engine label, falling back to that label for voices without one.
    var descriptionText: String { VoiceDescription.tagline(for: name, fallback: engineLabel) }

    // A fuller, 1-2 sentence description of the voice's character — used on
    // VoicePreviewSheet's card in place of the raw engine label.
    var longDescription: String { VoiceDescription.longDescription(for: name) }

    // Emoji flag for the voice's accent/locale, shown beside its name on
    // VoicePreviewSheet's card.
    var countryFlag: String { VoiceLocale.flag(for: name) }
}

/// One row per voice: cover image, name, a short persona tagline, and a
/// trailing play/pause indicator (reflects whether this voice's preview is
/// the one currently playing, started from VoicePreviewSheet). The whole
/// card is the tap target — tapping opens VoicePreviewSheet.
private struct VoiceTileView: View {
    let tile: VoiceTile
    @ObservedObject var viewModel: TTSViewModel
    let onTap: () -> Void

    private var isPreviewing: Bool { viewModel.previewingVoiceID == tile.name }

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

/// Voice avatars: a real, per-voice AI-generated cover image for voices
/// that have one, or an orb (`OrbCoverArt`, `DesignSystem/OrbCoverArt.swift`)
/// for every other voice — available or not, Kokoro or Pocket TTS. One
/// rule regardless of engine/download state, so every caller here can just
/// ask for "the" cover art without branching on availability itself.
enum VoiceCoverArt {
    // Real, per-voice AI-generated avatars (issue #18) — keyed by the exact
    // voice code. Sparse on purpose: only voices with a generated avatar
    // appear here; every other voice falls back to OrbCoverArt until its
    // own avatar exists. Add an entry here as each new avatar lands.
    private static let realAvatarAssetNames: [String: String] = [
        "af_heart": "VoiceAvatar_af_heart",
        "af_alloy": "VoiceAvatar_af_alloy",
        "af_nova": "VoiceAvatar_af_nova",
        "af_aoede": "VoiceAvatar_af_aoede",
        "af_bella": "VoiceAvatar_af_bella",
        "af_jessica": "VoiceAvatar_af_jessica",
        "af_kore": "VoiceAvatar_af_kore",
        "af_nicole": "VoiceAvatar_af_nicole",
        "af_river": "VoiceAvatar_af_river",
        "af_sarah": "VoiceAvatar_af_sarah",
        "af_sky": "VoiceAvatar_af_sky",
        "am_adam": "VoiceAvatar_am_adam",
        "am_liam": "VoiceAvatar_am_liam",
        "am_fenrir": "VoiceAvatar_am_fenrir",
        "bf_alice": "VoiceAvatar_bf_alice",
        "bm_daniel": "VoiceAvatar_bm_daniel",
        // Mandarin — hexgrad/Kokoro-82M's 8 officially-named voices only
        // (zf_001/zm_009 have no generated avatar yet, fall back to an orb
        // like any other voice without one — see TTSViewModel.mandarinVoices).
        "zf_xiaobei": "VoiceAvatar_zf_xiaobei",
        "zf_xiaoni": "VoiceAvatar_zf_xiaoni",
        "zf_xiaoxiao": "VoiceAvatar_zf_xiaoxiao",
        "zf_xiaoyi": "VoiceAvatar_zf_xiaoyi",
        "zm_yunjian": "VoiceAvatar_zm_yunjian",
        "zm_yunxi": "VoiceAvatar_zm_yunxi",
        "zm_yunxia": "VoiceAvatar_zm_yunxia",
        "zm_yunyang": "VoiceAvatar_zm_yunyang",
    ]

    static func assetName(for voiceName: String) -> String {
        realAvatarAssetNames[voiceName] ?? OrbCoverArt.assetName(for: voiceName)
    }
}

/// Short persona taglines shown under a voice's name in Trending voices,
/// instead of the raw engine label — same personas used to brief the
/// avatar images (issue #18), condensed to a couple of words. Sparse like
/// `VoiceCoverArt.realAvatarAssetNames`: falls back to the engine label for
/// any voice without one yet (currently all of Pocket TTS).
enum VoiceDescription {
    private static let taglines: [String: String] = [
        "af_heart": "Warm and friendly",
        "af_alloy": "Poised and composed",
        "af_aoede": "Dreamy and artistic",
        "af_bella": "Warm and confident",
        "af_jessica": "Friendly and professional",
        "af_kore": "Bright and youthful",
        "af_nicole": "Sophisticated and polished",
        "af_nova": "Vibrant and energetic",
        "af_river": "Free-spirited and relaxed",
        "af_sarah": "Sweet and genuine",
        "af_sky": "Bright and airy",
        "am_adam": "Warm and easygoing",
        "am_echo": "Sharp and composed",
        "am_eric": "Friendly and warm",
        "am_fenrir": "Rugged, deep voice",
        "am_liam": "Youthful and relaxed",
        "am_michael": "Reliable and warm",
        "am_onyx": "Sleek and cool",
        "am_puck": "Playful and mischievous",
        "am_santa": "Warm and jolly",
        "bf_alice": "Elegant and refined",
        "bf_emma": "Poised and elegant",
        "bf_isabella": "Graceful and refined",
        "bf_lily": "Gentle and delicate",
        "bm_daniel": "Distinguished and calm",
        "bm_fable": "Warm storyteller",
        "bm_george": "Distinguished and composed",
        "bm_lewis": "Friendly and approachable",
        // Mandarin — zf_001/zm_009 have no documented persona (FluidAudio's
        // hosted defaults), so a plain, honest tagline rather than a guess.
        // The 8 named voices below are hexgrad/Kokoro-82M's own official
        // Mandarin personas (VOICES.md) / Azure's original named personas
        // they're modeled on, not a guess like Pocket's below.
        "zf_001": "Clear and steady",
        "zm_009": "Clear and steady",
        "zf_xiaobei": "Warm and homely",
        "zf_xiaoni": "Clear and professional",
        "zf_xiaoxiao": "Warm and lively",
        "zf_xiaoyi": "Bright and expressive",
        "zm_yunjian": "Passionate and bold",
        "zm_yunxi": "Sunny and upbeat",
        "zm_yunxia": "Playful and youthful",
        "zm_yunyang": "Professional and reliable",
    ]

    static func tagline(for voiceName: String, fallback: String) -> String {
        taglines[voiceName] ?? fallback
    }

    // Fuller descriptions for VoicePreviewSheet's card — same
    // name-association-guess basis as the taglines above (Kokoro's
    // af_/am_/bf_/bm_ prefix gives real gender/accent; the character
    // adjectives are still a guess, not verified against each clip). Pocket
    // TTS voices are named after LibriVox-style audiobook narrators/
    // characters with no persona data at all, so those are freshly-written,
    // generic narration-toned descriptions rather than anything sourced.
    private static let longDescriptions: [String: String] = [
        "af_alloy": "Poised and composed, with a polished, professional edge — clear enough for crisp narration or presentations.",
        "af_aoede": "Dreamy and artistic, with a soft, unhurried delivery well suited to reflective or lyrical text.",
        "af_bella": "Warm and confident, with a rich, assured tone that carries a room.",
        "af_heart": "Warm and friendly, with an easy, conversational tone — great for everyday narration and casual reads.",
        "af_jessica": "Friendly and professional, with a clear, approachable delivery suited to explainers and guides.",
        "af_kore": "Bright and youthful, with an upbeat, energetic lift to every line.",
        "af_nicole": "Sophisticated and polished, with a smooth, refined cadence.",
        "af_nova": "Vibrant and energetic, with a lively pace that suits upbeat, fast-moving content.",
        "af_river": "Free-spirited and relaxed, with an unhurried, laid-back delivery.",
        "af_sarah": "Sweet and genuine, with a warm, down-to-earth tone that feels personal.",
        "af_sky": "Bright and airy, with a light, cheerful lilt.",
        "am_adam": "Warm and easygoing, with a relaxed, approachable delivery.",
        "am_echo": "Sharp and composed, with a crisp, confident edge.",
        "am_eric": "Friendly and warm, with a steady, welcoming tone.",
        "am_fenrir": "Rugged and deep, with a strong, grounded presence.",
        "am_liam": "Youthful and relaxed, with a casual, easy pace.",
        "am_michael": "Reliable and warm, with a dependable, trustworthy tone.",
        "am_onyx": "Sleek and cool, with a smooth, understated confidence.",
        "am_puck": "Playful and mischievous, with a light, spirited energy.",
        "am_santa": "Warm and jolly, with a hearty, good-natured cheer.",
        "bf_alice": "Elegant and refined, with a crisp, well-mannered British delivery.",
        "bf_emma": "Poised and elegant, with a graceful, composed tone.",
        "bf_isabella": "Graceful and refined, with a smooth, cultivated cadence.",
        "bf_lily": "Gentle and delicate, with a soft, soothing British lilt.",
        "bm_daniel": "Distinguished and calm, with an even, authoritative delivery.",
        "bm_fable": "A warm storyteller's voice, rich and expressive — built for narration.",
        "bm_george": "Distinguished and composed, with a steady, refined British tone.",
        "bm_lewis": "Friendly and approachable, with a warm, easy-going British manner.",
        "alba": "A clear, gentle narrator voice with a calm, steady pace.",
        "anna": "A warm, expressive voice well suited to storytelling and long-form reads.",
        "azelma": "A soft, measured voice with a quiet, thoughtful delivery.",
        "bill_boerst": "A steady, seasoned narrator voice with a relaxed, confident cadence.",
        "caro_davy": "A bright, articulate voice with a brisk, engaging pace.",
        "charles": "A calm, deliberate voice suited to serious or reflective narration.",
        "cosette": "A soft, youthful voice with a gentle, sincere tone.",
        "eponine": "An expressive, emotive voice with a slightly melancholic warmth.",
        "estelle": "A refined, articulate voice with a smooth, unhurried delivery.",
        "eve": "A clear, natural voice with an easy, conversational rhythm.",
        "fantine": "A tender, soft-spoken voice with a quiet emotional depth.",
        "george": "A steady, dependable voice with a classic narrator's tone.",
        "giovanni": "A warm, expressive voice with a touch of theatrical flair.",
        "jane": "A composed, articulate voice with a gentle, measured pace.",
        "javert": "A firm, resolute voice with a serious, commanding edge.",
        "jean": "A grounded, weathered voice with quiet, steady conviction.",
        "juergen": "A deep, deliberate voice with a calm, authoritative presence.",
        "lola": "A lively, expressive voice with a playful, energetic lift.",
        "marius": "A youthful, earnest voice with an open, sincere tone.",
        "mary": "A warm, gentle voice with a comforting, familiar quality.",
        "michael": "A clear, confident voice suited to straightforward narration.",
        "paul": "A steady, even voice with an unassuming, practical tone.",
        "peter_yearsley": "A rich, classic narrator's voice with a measured, deliberate pace.",
        "rafael": "A warm, textured voice with an expressive, animated delivery.",
        "stuart_bell": "A crisp, articulate voice with a brisk, professional pace.",
        "vera": "A soft, composed voice with a calm, reassuring tone.",
        "zf_001": "A clear, steady Mandarin voice — the standard default for everyday narration.",
        "zm_009": "A clear, steady Mandarin voice with an even, dependable delivery.",
        "zf_xiaobei": "Warm and natural, carrying a touch of Northeastern Chinese character — easy, conversational delivery.",
        "zf_xiaoni": "Clear and composed, with a Shaanxi-inflected warmth well suited to informational content.",
        "zf_xiaoxiao": "Warm and lively — a flagship Mandarin persona, expressive across a wide emotional range.",
        "zf_xiaoyi": "Bright and expressive, with a youthful energy that shifts easily between playful and heartfelt.",
        "zm_yunjian": "Passionate and dynamic, built for sports commentary and dramatic narration.",
        "zm_yunxi": "Sunny and upbeat, with a lively conversational warmth.",
        "zm_yunxia": "Playful and youthful — a bright, cheerful young voice.",
        "zm_yunyang": "Professional and reliable, with the composed authority of a news anchor.",
    ]

    static func longDescription(for voiceName: String) -> String {
        longDescriptions[voiceName] ?? "A distinctive voice with its own character."
    }
}

/// Emoji flag for a voice's accent/locale, derived from Kokoro's own
/// af_/am_ (American) / bf_/bm_ (British) naming convention. Pocket TTS
/// voices carry no locale info in their name at all — those default to US
/// English until real per-voice locale data exists; flag this assumption if
/// it turns out wrong for a specific voice.
enum VoiceLocale {
    static func flag(for voiceName: String) -> String {
        if voiceName.hasPrefix("bf_") || voiceName.hasPrefix("bm_") {
            return "🇬🇧"
        }
        if voiceName.hasPrefix("zf_") || voiceName.hasPrefix("zm_") {
            return "🇨🇳"
        }
        return "🇺🇸"
    }
}

#Preview {
    let dependencies = DependencyContainer()
    ImportHomeView(
        viewModel: TTSViewModel(dependencies: dependencies),
        voiceCloneViewModel: VoiceCloneViewModel(dependencies: dependencies),
        libraryViewModel: LibraryViewModel())
}
