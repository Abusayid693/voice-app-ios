import LucideSwift
import PDFKit
import SwiftUI

/// The reader's original-page mode: one rendered PDF page with the chunk being
/// spoken highlighted on it.
///
/// Rendered to an image rather than hosted in a `PDFView`. `PDFView` would give
/// native zoom for free, but it owns its own scrolling and gesture recognisers,
/// and this screen already has a horizontal page-turn swipe, tap-to-seek and
/// auto-scroll to coordinate — so it would be fighting for every touch. An
/// image plus a SwiftUI overlay also reuses the fractional coordinate system
/// `ReaderTextRect` already stores, which needs no page dimensions to place.
struct ReaderPDFPageView: View {
    let pdfURL: URL
    let pageIndex: Int
    /// Fractions of the page (0...1, top-left origin) — normally the lines the
    /// currently-spoken chunk occupies.
    let highlights: [CGRect]
    let theme: ReaderTheme

    @State private var page: UIImage?
    @State private var isRendering = true
    @State private var zoomScale: CGFloat = 1
    @State private var settledZoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var settledZoomOffset: CGSize = .zero

    private let maximumZoomScale: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let size = renderedSize(fitting: proxy.size)
            ZStack {
                if let page {
                    pageImage(page, size: size)
                        .scaleEffect(zoomScale)
                        .offset(zoomOffset)
                } else if isRendering {
                    ProgressView().tint(theme.primaryText)
                } else {
                    unavailable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .clipped()
            .gesture(zoomGesture(pageSize: size, viewportSize: proxy.size))
            .onTapGesture(count: 2) { toggleZoom() }
            .accessibilityAction(named: "Zoom in") {
                setZoom(min(maximumZoomScale, settledZoomScale + 1))
            }
            .accessibilityAction(named: "Zoom out") {
                setZoom(max(1, settledZoomScale - 1))
            }
            .accessibilityAction(named: "Reset zoom") { setZoom(1) }
        }
        .task(id: pageIndex) {
            resetZoom()
            await render()
        }
    }

    private func pageImage(_ image: UIImage, size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .overlay { highlightLayer(in: size) }
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(theme.secondaryText.opacity(0.25), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func zoomGesture(pageSize: CGSize, viewportSize: CGSize) -> some Gesture {
        let magnification = MagnificationGesture()
            .onChanged { value in
                zoomScale = min(max(settledZoomScale * value, 0.85), maximumZoomScale + 0.2)
                zoomOffset = clampedOffset(
                    zoomOffset, pageSize: pageSize, viewportSize: viewportSize,
                    scale: max(zoomScale, 1))
            }
            .onEnded { _ in
                settleZoom(pageSize: pageSize, viewportSize: viewportSize)
            }

        let pan = DragGesture(minimumDistance: 5)
            .onChanged { value in
                guard zoomScale > 1 else { return }
                let proposed = CGSize(
                    width: settledZoomOffset.width + value.translation.width,
                    height: settledZoomOffset.height + value.translation.height)
                zoomOffset = clampedOffset(
                    proposed, pageSize: pageSize, viewportSize: viewportSize,
                    scale: zoomScale)
            }
            .onEnded { _ in
                settleZoom(pageSize: pageSize, viewportSize: viewportSize)
            }

        return magnification.simultaneously(with: pan)
    }

    private func settleZoom(pageSize: CGSize, viewportSize: CGSize) {
        let scale = min(max(zoomScale, 1), maximumZoomScale)
        let offset = clampedOffset(
            scale == 1 ? .zero : zoomOffset,
            pageSize: pageSize, viewportSize: viewportSize, scale: scale)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            zoomScale = scale
            zoomOffset = offset
        }
        settledZoomScale = scale
        settledZoomOffset = offset
    }

    private func clampedOffset(
        _ proposed: CGSize, pageSize: CGSize, viewportSize: CGSize, scale: CGFloat
    ) -> CGSize {
        let maximumX = max((pageSize.width * scale - viewportSize.width) / 2, 0)
        let maximumY = max((pageSize.height * scale - viewportSize.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY))
    }

    private func toggleZoom() {
        setZoom(settledZoomScale > 1 ? 1 : 2.5)
    }

    private func setZoom(_ requestedScale: CGFloat) {
        let scale = min(max(requestedScale, 1), maximumZoomScale)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            zoomScale = scale
            zoomOffset = .zero
        }
        settledZoomScale = scale
        settledZoomOffset = .zero
    }

    private func resetZoom() {
        zoomScale = 1
        settledZoomScale = 1
        zoomOffset = .zero
        settledZoomOffset = .zero
    }

    private var unavailable: some View {
        VStack(spacing: 10) {
            LucideIcon(.fileText, size: 32, color: theme.secondaryText)
            Text("This page could not be rendered.")
                .appText(.body)
                .foregroundStyle(theme.secondaryText)
        }
    }

    /// Fits the page inside the available space at its own aspect ratio, which
    /// is what keeps the fractional highlight rects aligned — they only hold if
    /// the image is never stretched.
    private func renderedSize(fitting available: CGSize) -> CGSize {
        guard let page, page.size.width > 0, page.size.height > 0 else { return available }
        let scale = min(
            available.width / page.size.width, available.height / page.size.height)
        return CGSize(width: page.size.width * scale, height: page.size.height * scale)
    }

    /// Marks the spoken lines the way a highlighter pen does: the paper takes
    /// the colour and the type stays black.
    ///
    /// `.multiply` rather than a translucent fill is what buys that. Alpha
    /// compositing lightens the glyphs underneath toward the highlight colour,
    /// so the text faded exactly where you are meant to be reading; multiplying
    /// leaves white paper as the colour and black type as black.
    ///
    /// The rects are filled opaque inside one `compositingGroup`, and the blend
    /// applies to that flattened result rather than to each rect. Otherwise
    /// every overlap between two line rects multiplies twice and darkens, which
    /// is what gave the old translucent version its blotchy, blobbed edges.
    private func highlightLayer(in size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(highlights.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.pdfPageHighlight)
                    .frame(width: rect.width * size.width, height: rect.height * size.height)
                    .offset(x: rect.minX * size.width, y: rect.minY * size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .compositingGroup()
        .blendMode(.multiply)
        .animation(.easeOut(duration: 0.18), value: highlights)
        .allowsHitTesting(false)
    }

    /// Off the main actor: opening a document and rasterising a page is slow
    /// enough to drop frames, and this screen polls word highlighting at ~12Hz.
    private func render() async {
        isRendering = true
        let url = pdfURL
        let index = pageIndex
        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            autoreleasepool {
                guard let document = PDFDocument(url: url),
                      let page = document.page(at: index)
                else { return nil }
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width > 0, bounds.height > 0 else { return nil }
                // 2x the page's own points keeps text crisp when the page is
                // scaled up to fill a phone screen, without the memory a full
                // device-scale render of a large page would take.
                let target = CGSize(width: bounds.width * 2, height: bounds.height * 2)
                return page.thumbnail(of: target, for: .cropBox)
            }
        }.value
        page = rendered
        isRendering = false
    }
}
