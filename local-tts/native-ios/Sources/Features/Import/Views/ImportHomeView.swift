import Hugeicons
import LucideSwift
import SwiftUI
import UniformTypeIdentifiers

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

/// The two pages of Home's top action row — "Listen to text" (get
/// existing text into the app) vs. "Make audio" (create new voice/audio
/// content).
private enum HomeTab: Hashable, Identifiable, CaseIterable {
    case listen, make

    var id: Self { self }

    var title: String {
        switch self {
        case .listen: return "Listen to text"
        case .make: return "Make audio"
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
    @ObservedObject var libraryViewModel: LibraryViewModel
    @ObservedObject var pdfImports: PDFImportManager
    // Observed: this screen's tile availability and the Setup pointer both
    // read pack readiness.
    @ObservedObject var packs: VoicePackStore
    // Everything this screen only hands onward — the cloned-voice model,
    // the preview player (its ~15x/sec metering would re-render this whole
    // page), and the two chapter objects — arrives in one non-observable
    // container rather than as four separate parameters, so none of it
    // subscribes this view to anything. See AppEnvironment.
    let app: AppEnvironment
    // Owned here (not TTSViewModel) — book browsing is a separate concern
    // from TTS orchestration, and outlives this view's re-renders as long
    // as the Import tab stays alive.
    @StateObject private var openLibraryBooksViewModel = OpenLibraryBooksViewModel()
    // Same reasoning as openLibraryBooksViewModel above — owned here, not
    // TTSViewModel, and outlives re-renders for the life of this view.
    @StateObject private var classicReadsViewModel = ClassicReadsViewModel()
    // Which voice's preview sheet is open, if any — pure navigation state
    // for this screen, not shared elsewhere, so it lives here rather than
    // on TTSViewModel.
    @State private var selectedVoiceTile: VoiceTile?
    @State private var isCreateVoicePresented = false
    @State private var voiceCloneRoute: VoiceCloneRoute?
    @State private var isSettingsPresented = false
    // Set when tapping a Projects entry (any engine) — opens page 1.
    // for that saved project.
    @State private var openProject: SavedGeneration?
    // Set by WriteTextView's onGenerated the moment Generate saves a new
    // project, but not applied to openProjectID until the fullScreenCover's
    // own onDismiss fires — setting both isWriteTextPresented = false and
    // openProjectID in the same runloop can drop the subsequent push.
    @State private var pendingProjectID: UUID?
    // Setup pointer only makes sense while its target is still visible at
    // the top of the screen — hide it the moment the user scrolls away
    // from the top, rather than have it float over unrelated content.
    // Driven by ScrolledToTopObserver above.
    @State private var isScrolledToTop = true
    // Which page of the action tabs is showing — tapping a tab and
    // swiping the TabView both write to this same binding, so either one
    // keeps the other in sync.
    @State private var selectedHomeTab: HomeTab = .listen

    private var isFullyDownloaded: Bool {
        packs.isKokoroPackReady && packs.isPocketPackDownloaded && packs.isSupertonic3Downloaded
    }

    private var selectedVoiceName: String {
        switch viewModel.engine {
        case .kokoroAne: return viewModel.kokoroVoice
        case .pocketTts: return viewModel.selectedClonedVoice?.name ?? viewModel.pocketVoice
        case .supertonic3: return viewModel.supertonicVoice.displayName
        }
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

            if isScrolledToTop {
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
                // 4 top-level groups (buttons, Trending voices, Read
                // Anything, Projects) at AppSpacing.betweenGroups; within a
                // multi-part group, siblings sit at the tighter
                // AppSpacing.betweenSections instead.
                VStack(alignment: .leading, spacing: AppSpacing.betweenGroups) {
                    actionTabsSection

                    VStack(alignment: .leading, spacing: AppSpacing.betweenSections) {
                        trendingVoicesSection
                        createYourOwnVoiceRow
                    }

                    VStack(alignment: .leading, spacing: AppSpacing.betweenSections) {
                        readAnythingSection
                        ClassicReadsSection(viewModel: classicReadsViewModel)
                        newInRomanceSection
                        createYourOwnBookRow
                    }

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
            .task { await openLibraryBooksViewModel.loadIfNeeded() }
            .navigationDestination(item: $voiceCloneRoute) { route in
                switch route {
                case .instantClone:
                    InstantCloneView(viewModel: app.voiceClone) { voiceCloneRoute = nil }
                case .upload:
                    UploadVoiceView(viewModel: app.voiceClone) { voiceCloneRoute = nil }
                }
            }
            .navigationDestination(item: $openProject) { project in
                ChapterPlayerView(
                    project: project, library: libraryViewModel,
                    voiceCloneViewModel: app.voiceClone,
                    chapterPlayer: app.chapterPlayer,
                    generationStore: app.generationStore, viewModel: viewModel)
            }
            // The root tab bar/floating "+" button should only show at
            // this screen's own root, not on anything pushed above it —
            // see NavigationChromeVisibility. Two triggers, either one
            // non-nil means something's pushed.
            .tabRootChrome(app.navigationChrome, isPushed: openProject != nil || voiceCloneRoute != nil)
        }
        .sheet(isPresented: $viewModel.isSetupPresented) {
            SetupSheet(viewModel: viewModel, packs: packs)
        }
        .fullScreenCover(
            isPresented: $viewModel.isWriteTextPresented,
            onDismiss: {
                if let pendingProjectID {
                    openProject = libraryViewModel.project(for: pendingProjectID)
                    self.pendingProjectID = nil
                }
            }
        ) {
            WriteTextView(
                viewModel: viewModel, voiceCloneViewModel: app.voiceClone,
                libraryViewModel: libraryViewModel, packs: packs,
                onGenerated: { projectID in
                    pendingProjectID = projectID
                    viewModel.isWriteTextPresented = false
                })
        }
        .sheet(isPresented: $isCreateVoicePresented) {
            CreateVoiceSheet { route in
                isCreateVoicePresented = false
                voiceCloneRoute = route
            }
        }
        .sheet(item: $selectedVoiceTile) { tile in
            VoicePreviewSheet(tiles: voiceTiles, initialTileID: tile.id, previewPlayer: app.previewPlayer)
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet(viewModel: viewModel, voiceCloneViewModel: app.voiceClone)
        }
        .fileImporter(
            isPresented: $pdfImports.isDocumentPickerPresented,
            allowedContentTypes: [.pdf], allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                await pdfImports.importPDF(
                    from: url, engine: viewModel.engine, voiceName: selectedVoiceName)
            }
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

    // Tab switcher + swipeable pages, both driving the same
    // `selectedHomeTab` binding — tapping a tab and swiping the TabView
    // are just two ways to write to it, so they can never disagree.
    private var actionTabsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sectionToContent) {
            homeTabSwitcher

            TabView(selection: $selectedHomeTab) {
                listenActionsGrid.tag(HomeTab.listen)
                makeAudioActionsGrid.tag(HomeTab.make)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Matches the grid's own natural height (2 rows of
            // ImportActionCard's 80pt content + 16pt padding on each
            // side = 112pt per card, + 12pt row spacing) — TabView
            // doesn't size to its pages' content on its own.
            .frame(height: 236)
            // Cancels the parent VStack's .padding(.horizontal) so the
            // TabView's own drag area spans the true screen edge-to-edge
            // (same trick trendingVoicesSection uses) — each grid re-adds
            // the same 16pt as its own content inset, so the cards still
            // sit exactly where they did before.
            .padding(.horizontal, -16)
        }
    }

    private var homeTabSwitcher: some View {
        HStack(spacing: 8) {
            ForEach(HomeTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedHomeTab = tab }
                } label: {
                    Text(tab.title)
                        .appText(.rowTitle)
                        .foregroundStyle(selectedHomeTab == tab ? Color.appPrimaryText : Color.appSecondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            selectedHomeTab == tab ? Color.appSecondaryBackground : Color.clear,
                            in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // "Listen to text" — get existing text into the app to have it read
    // aloud. Only "Write text" is functional today; the rest are visual
    // placeholders per the current design pass (same status as before
    // this row grew tabs).
    private var listenActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ImportActionCard(title: "Paste a link", icon: .link, action: {})
            ImportActionCard(title: "Upload a file", icon: .file) {
                pdfImports.requestDocumentPicker()
            }
            ImportActionCard(title: "Scan text", icon: .scan, action: {})
            ImportActionCard(title: "Write text", icon: .textCursor) {
                viewModel.isWriteTextPresented = true
            }
        }
        .padding(.horizontal, 16)
    }

    // "Make audio" — create new voice/audio content. All 4 are visual
    // placeholders for now, same status as most of "Listen to text"'s row.
    private var makeAudioActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ImportActionCard(title: "Clone voice", icon: .mic, action: {})
            ImportActionCard(title: "Upload Book", icon: .bookUp) {
                pdfImports.requestDocumentPicker()
            }
            ImportActionCard(title: "Create Podcast", icon: .radio, action: {})
            ImportActionCard(title: "Change Voice", icon: .repeatIcon, action: {})
        }
        .padding(.horizontal, 16)
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
        return kokoro + pocket + supertonic3
    }

    private var trendingVoicesSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sectionToContent) {
            Text("Trending voices").appText(.sectionTitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(
                    rows: [
                        GridItem(.fixed(60), spacing: 14), GridItem(.fixed(60), spacing: 16),
                    ], spacing: 0
                ) {
                    ForEach(voiceTiles) { tile in
                        PreviewVoiceCard(tile: tile, previewPlayer: app.previewPlayer) {
                            selectedVoiceTile = tile
                        }
                    }
                }
                // Each tile becomes a snap candidate; for a 2-row grid this
                // snaps per column (both stacked tiles at that horizontal
                // offset), not per individual tile.
                .scrollTargetLayout()
                .padding(.horizontal, 2)
            }
            .scrollTargetBehavior(.viewAligned)
            .padding(.horizontal, -16)
        }
    }

    // Real, unlike createYourOwnBookRow below — opens the same CreateVoiceSheet
    // (Instant Clone / Upload file) as the Voices tab's own entry point.
    private var createYourOwnVoiceRow: some View {
        CreateYourOwnRow(
            icon: Hugeicons.mic01, title: "Create your own voice",
            subtitle: "Clone your voice in seconds"
        ) {
            isCreateVoicePresented = true
        }
    }

    // "Read Anything" — a horizontally scrolling row of promo cards, one
    // card per item so more can be appended later. Card width/image size
    // are fixed per the supplied design (327x188 image, full card width
    // 327), not derived from screen width.
    private var readAnythingSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sectionToContent) {
            Text("Read Anything").appText(.sectionTitle)
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

    // No "See all" yet — see OpenLibraryBooksViewModel's doc comment.
    private var newInRomanceSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.innerSectionToContent) {
            Text("New in romance").appText(.sectionTitle)

            if openLibraryBooksViewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else if let errorMessage = openLibraryBooksViewModel.loadErrorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .appText(.body)
                    // Font only — stays system accent-tinted so it still
                    // reads as tappable, matching every other bare toolbar/
                    // text button in this app (none carry an app color).
                    Button("Retry") {
                        Task { await openLibraryBooksViewModel.retry() }
                    }
                    .font(AppTextStyle.body.font)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(openLibraryBooksViewModel.books) { book in
                            OpenLibraryBookCard(book: book)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    private var createYourOwnBookRow: some View {
        CreateYourOwnRow(
            icon: Hugeicons.plusSign, title: "Create your own book",
            subtitle: "Craft your own story in seconds"
        ) {}
    }

    // Real generations (latest 5, newest first) once any exist; falls back
    // to the static demo row + a "Create your own project" entry point
    // (no action yet, matching createYourOwnBookRow's own no-op) while the
    // library is still empty.
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sectionToContent) {
            Text("Projects").appText(.sectionTitle)
            ForEach(pdfImports.jobs.filter { $0.phase != .completed && $0.phase != .cancelled }.prefix(2)) { job in
                PDFImportJobCard(job: job, manager: pdfImports)
            }
            if libraryViewModel.savedGenerations.isEmpty {
                ForEach(DemoContent.projects) { project in
                    projectRow(title: project.title, subtitle: project.subtitle, updatedLabel: project.updatedLabel)
                }
                createYourOwnProjectRow
            } else {
                ForEach(libraryViewModel.savedGenerations.prefix(5)) { generation in
                    GenerationRow(
                        icon: generation.engine == .kokoroAne ? .audioWaveform : .mic,
                        iconStyle: generation.engine == .kokoroAne ? .stroked : .filled,
                        coverURL: generation.coverURL,
                        title: generation.title,
                        subtitle:
                            "\(generation.pageCountLabel) · \(VoiceDisplayName.forCode(generation.voiceName)) · \(generation.createdAt.formatted(date: .abbreviated, time: .shortened))",
                        onTap: { openProject = libraryViewModel.project(for: generation.id) }
                    )
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
                Text(title).appText(.rowTitle)
                Text(subtitle).appText(.label)
                    .lineLimit(1)
                Text(updatedLabel).appText(.labelDim)
            }
            Spacer()
            Hugeicons.play.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 22, height: 22)
        }
        .contentShape(Rectangle())
    }

    private var createYourOwnProjectRow: some View {
        Button(action: {}) {
            HStack(spacing: 12) {
                LucideIcon(.circlePlus, size: 28, color: Color.appPrimaryText)
                Text("Create your own project").appText(.rowTitle)
                Spacer()
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appSecondaryBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

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
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .leading) {
                    if item.showsPlayButton {
                        LucideIcon(.circlePlay, size: 36, color: Color(hex: 0xD5AB80))
                            .padding(.leading, 29)
                    }
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).appText(.cardTitle)
                Text(item.description).appText(.label)
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
                    .appText(.rowTitle)
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
#Preview {
    let app = AppEnvironment.preview()
    return ImportHomeView(
        viewModel: app.tts, libraryViewModel: app.library, pdfImports: app.pdfImports,
        packs: app.tts.packs, app: app)
}
