import SwiftUI

/// Presentation coordinates only; the shelf's persisted layout never follows the finger.
struct ShelfBookDrag {
    let sourceFrame: CGRect
    let coverSize: CGSize
    let liftedCenter: CGPoint
}

enum ShelfMoveDirection {
    case earlier, later, shelfAbove, shelfBelow
}

/// Attach to the shelf viewport, so scrolling a source row offscreen cannot end its drag.
struct ShelfLiftDragGesture: ViewModifier {
    var requiresLongPress = true
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    @GestureState private var isDragging = false

    func body(content: Content) -> some View {
        trackedContent(content)
            .onChange(of: isDragging) { _, active in
                if !active {
                    Task { @MainActor in
                        await Task.yield()
                        onCancelled()
                    }
                }
            }
    }

    @ViewBuilder
    private func trackedContent(_ content: Content) -> some View {
        if requiresLongPress {
            content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(bookShelfModalCoordinateSpace)))
                    .updating($isDragging) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
                    .onChanged { value in
                        if case .second(true, let drag) = value, let drag { onChanged(drag) }
                    }
                    .onEnded { _ in onEnded() })
        } else {
            content.gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(bookShelfModalCoordinateSpace))
                    .updating($isDragging) { _, state, _ in state = true }
                    .onChanged(onChanged)
                    .onEnded { _ in onEnded() })
        }
    }
}

struct ShelfDraggedBook: View {
    let book: SavedGenerationSummary
    let mode: ShelfDisplayMode
    let drag: ShelfBookDrag

    var body: some View {
        Color.clear
            .frame(
                width: mode == .spine ? book.spineWidth : drag.coverSize.width,
                height: drag.coverSize.height)
            .overlay(alignment: .leading) {
                RotatingBookFaces(
                    coverURL: book.coverURL, title: book.title,
                    coverSize: drag.coverSize, spineWidth: book.spineWidth,
                    spineArtworkURL: book.spineArtworkURL,
                    angle: mode == .spine ? 90 : 0)
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
            .position(drag.liftedCenter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ShelfArrangeOverlay: View {
    @ObservedObject var motion: BookShelfDragMotion
    let book: SavedGenerationSummary
    let mode: ShelfDisplayMode
    let drag: ShelfBookDrag?
    let preparedDrag: ShelfBookDrag?
    let restingAnchor: CGRect?
    let onRotate: () -> Void
    let onDelete: () -> Void

    private var anchor: CGRect? {
        guard let drag else { return restingAnchor }
        let width = mode == .spine ? book.spineWidth : drag.coverSize.width
        return CGRect(
            x: drag.liftedCenter.x + motion.translation.width - width / 2,
            y: drag.liftedCenter.y + motion.translation.height - drag.coverSize.height / 2,
            width: width, height: drag.coverSize.height)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Mount and load at lift-off, then reuse this exact view when dragging starts.
            if let renderDrag = drag ?? preparedDrag {
                ShelfDraggedBook(book: book, mode: mode, drag: renderDrag)
                    .opacity(drag == nil ? 0 : 1)
                    .animation(nil, value: drag == nil)
                    .offset(motion.translation)
                    .transition(.identity)
            }
            BookArrangeMenu(isSpine: mode == .spine, anchor: anchor,
                            onRotate: onRotate, onDelete: onDelete)
                .allowsHitTesting(drag == nil)
        }
    }
}
