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

    var body: some View {
        GeometryReader { proxy in
            let size = renderedSize(fitting: proxy.size)
            ZStack {
                if let page {
                    Image(uiImage: page)
                        .resizable()
                        .scaledToFit()
                        .frame(width: size.width, height: size.height)
                        .overlay { highlightLayer(in: size) }
                        // Confines the highlight's `.multiply` to the page it
                        // marks. A blend mode composites against whatever sits
                        // beneath it in the same group, which without this is
                        // the screen's own background as well as the page.
                        .compositingGroup()
                        // The page is paper-white whatever the reader theme is,
                        // so it needs its own edge rather than dissolving into
                        // a light background.
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(theme.secondaryText.opacity(0.25), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                } else if isRendering {
                    ProgressView().tint(theme.primaryText)
                } else {
                    unavailable
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: pageIndex) { await render() }
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
