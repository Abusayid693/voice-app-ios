import Hugeicons
import SwiftUI

/// My Shelf's tab root. App-wide tabs, imports, Settings, and reader routing
/// are owned by `RootTabView`; this view owns only Shelf presentation state.
struct ImportHomeView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    let app: AppEnvironment
    @Binding var isBookDetailPresented: Bool
    let onPresentSettings: () -> Void
    let onAddBooks: () -> Void
    let onOpenReader: (ReaderRoute) -> Void

    var body: some View {
        BookShelfView(
            library: libraryViewModel,
            importShelf: app.pdfImports.shelfStore,
            pdfImports: app.pdfImports,
            readingStats: app.readingStats,
            isDetailPresented: $isBookDetailPresented,
            onOpenBook: { summary in
                guard let project = libraryViewModel.project(for: summary.id) else { return }
                onOpenReader(
                    ReaderRoute(
                        project: project,
                        initialPageIndex: nil,
                        initialSurfaceMode: nil))
            },
            onListen: { summary in
                guard let project = libraryViewModel.project(for: summary.id) else { return }
                onOpenReader(
                    ReaderRoute(
                        project: project,
                        initialPageIndex: nil,
                        initialSurfaceMode: .audio))
            },
            // `app` is held as a plain `let` here, so reaching the player
            // through it to call one method subscribes this view to nothing.
            onProjectUnavailable: { app.player.stopIfActive(projectID: $0) })
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            ShelfTopBlur().ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .top) { headerControls }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var headerControls: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsButton
                .padding(.leading, 16 - (44 - 25.3) / 2)

            Spacer(minLength: 0)

            addBooksButton
                .padding(.trailing, 10)
        }
        .padding(.top, 4)
    }

    private var settingsButton: some View {
        Button(action: onPresentSettings) {
            Hugeicons.menu02.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(BookShelfPalette.primaryText.opacity(0.7))
                .frame(width: 25.3, height: 25.3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressOpacity)
        .disabled(isBookDetailPresented)
        .accessibilityLabel("Settings")
    }

    private var addBooksButton: some View {
        Button(action: onAddBooks) {
            Text("+")
                .font(.custom("EBGaramond-Italic", size: 32, relativeTo: .title))
                .fontWeight(.medium)
                .foregroundStyle(Color.white)
                // EB Garamond's ascender metrics leave the visible plus low
                // inside a square frame; compensate optically without moving
                // the button's hit target or glass surface.
                .offset(y: -3)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.pressOpacity)
        .modifier(ShelfAddBooksSurface())
        .disabled(isBookDetailPresented)
        .accessibilityLabel("Add Books")
        .accessibilityHint("Choose a PDF or EPUB to add to your shelf")
    }
}

private struct ShelfAddBooksSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.tabSelected, in: Circle())
    }
}

#Preview {
    let app = AppEnvironment.preview()
    return NavigationStack {
        ImportHomeView(
            libraryViewModel: app.library,
            app: app,
            isBookDetailPresented: .constant(false),
            onPresentSettings: {},
            onAddBooks: {},
            onOpenReader: { _ in })
    }
}
