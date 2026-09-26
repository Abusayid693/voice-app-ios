import LucideSwift
import SwiftUI

/// The Explore menu's Tools route, pushed onto Home's stack — a list of
/// quick actions for starting a new reader project. Replaces the former
/// `PlaceholderTabView` "coming soon" stand-in.
struct ToolsView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let app: AppEnvironment
    let onAddBooks: () -> Void

    @State private var isWriteTextPresented = false
    @State private var isPlaybackLabPresented = false
    @State private var openProject: SavedGeneration?

    var body: some View {
        List {
            Section {
                ToolActionRow(
                    icon: .pencil, title: "Write a Text",
                    subtitle: "Type or paste text to turn into audio", isEnabled: true
                ) {
                    isWriteTextPresented = true
                }
                ToolActionRow(
                    icon: .upload, title: "Upload File",
                    subtitle: "Import a PDF from your device", isEnabled: true,
                    onTap: onAddBooks)
                // Share Link and Upload Image have no backend yet — no URL
                // content fetcher and no image/OCR pipeline exist anywhere
                // in this app. Shown rather than omitted (both were asked
                // for explicitly), disabled rather than faked.
                ToolActionRow(
                    icon: .link, title: "Share Link",
                    subtitle: "Coming soon", isEnabled: false
                ) {}
                ToolActionRow(
                    icon: .image, title: "Upload Image",
                    subtitle: "Coming soon", isEnabled: false
                ) {}
                // A scratch harness, not a shipping feature: paste a long text
                // and check whether synthesis keeps ahead of playback with the
                // screen locked.
                ToolActionRow(
                    icon: .headphones, title: "Background Playback",
                    subtitle: "Test continuous play with the screen locked",
                    isEnabled: true
                ) {
                    isPlaybackLabPresented = true
                }
            }
            .listRowBackground(Color.appSecondaryBackground)
        }
        .scrollContentBackground(.hidden)
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Tools")
        // Same reasoning as VoicesTabView/LibraryTabView — the nav bar is
        // UIKit-bridged chrome that doesn't read the `.environment` override
        // ImportHomeView applies at the push site, only `.preferredColorScheme`/
        // `.toolbarColorScheme`.
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(isPresented: $isPlaybackLabPresented) {
            StreamingPlaybackLabView(viewModel: app.tts)
        }
        .navigationDestination(isPresented: $isWriteTextPresented) {
            WriteTextView(library: libraryViewModel, viewModel: app.tts) { project in
                openProject = project
            }
        }
        .navigationDestination(item: $openProject) { project in
            ChapterPlayerView(
                project: project,
                library: libraryViewModel,
                chapterPlayer: app.chapterPlayer,
                generationStore: app.generationStore,
                viewModel: app.tts,
                previewPlayer: app.previewPlayer,
                readingStats: app.readingStats)
        }
    }
}

/// One tappable action row — icon avatar, title/subtitle, trailing chevron.
/// Deliberately its own lightweight type rather than reusing `GenerationRow`
/// (DesignSystem), which is shaped around a saved generation's cover art and
/// play affordance, not a generic action menu.
private struct ToolActionRow: View {
    let icon: LucideIconName
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.appBackground)
                    .frame(width: 40, height: 40)
                    .overlay { LucideIcon(icon, size: 18, color: Color.appPrimaryText) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appText(.rowTitle)
                    Text(subtitle).appText(.label)
                }

                Spacer(minLength: 8)

                if isEnabled {
                    LucideIcon(.chevronRight, size: 16, color: Color.appTertiaryText)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

#Preview {
    let app = AppEnvironment.preview()
    NavigationStack {
        ToolsView(libraryViewModel: app.library, app: app, onAddBooks: {})
    }
    .preferredColorScheme(.dark)
}
