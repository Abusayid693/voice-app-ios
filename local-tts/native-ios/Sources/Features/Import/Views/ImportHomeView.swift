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
            })
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
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.tabInactive(for: .light))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.pressOpacity)
        .modifier(ShelfAddBooksGlass())
        .disabled(isBookDetailPresented)
        .accessibilityLabel("Add Books")
        .accessibilityHint("Choose a PDF or EPUB to add to your shelf")
    }
}

private struct ShelfAddBooksGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.clear.interactive(), in: Circle())
                .shadow(color: Color.tabInactive(for: .light).opacity(0.28), radius: 7, y: 2)
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.75)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .shadow(color: Color.tabInactive(for: .light).opacity(0.28), radius: 7, y: 2)
        }
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
