import SwiftUI

/// Import's "Classic reads" row — restyled to the supplied "Top picks"
/// mockup: one large hero card at a time, cover flush against the leading
/// edge, the next card peeking in from the trailing edge. Deliberately a
/// different card language from every other row on this screen (small
/// square-grid cards) — that's what the mockup specifies for this row, a
/// genuine one-off style departure rather than an oversight.
///
/// Reuses `VoicePreviewSheet`'s peek/snap mechanism
/// (`.scrollTargetBehavior(.viewAligned)` + `.contentMargins(for:
/// .scrollContent)`), adapted to a single trailing-only peek since this is
/// a home-screen row, not a full-bleed sheet — the leading edge gets no
/// margin, so the first (and every snapped) card sits flush left.
struct ClassicReadsSection: View {
    @ObservedObject var viewModel: ClassicReadsViewModel

    // leadingMargin keeps the resting card aligned with the header text and
    // every other row (which all sit inside the screen's normal padding);
    // trailingPeek is how much of the next card shows beyond it.
    private let leadingMargin: CGFloat = 16
    private let trailingPeek: CGFloat = 32
    private let cardSpacing: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.innerSectionToContent) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Classic reads").appText(.sectionTitle)
                Text("Free, public-domain classics").appText(.label)
            }

            // Cancels ImportHomeView's outer .padding(.horizontal) (same
            // trick readAnythingSection uses) so the ScrollView's own frame
            // spans the true screen edge-to-edge — otherwise its clipping
            // bounds sit inset by that outer padding and the peeking card
            // reads as cut off rather than smoothly scrolled past.
            GeometryReader { geometry in
                let cardWidth = max(geometry.size.width - leadingMargin - trailingPeek, 0)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: cardSpacing) {
                        ForEach(viewModel.items) { item in
                            ClassicReadBigCard(item: item, onPlayTapped: viewModel.playRandomPreview)
                                .frame(width: cardWidth)
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .contentMargins(.leading, leadingMargin, for: .scrollContent)
                .contentMargins(.trailing, trailingPeek, for: .scrollContent)
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, -16)
            .frame(height: ClassicReadBigCard.cardHeight)
        }
    }
}

#Preview {
    ClassicReadsSection(viewModel: ClassicReadsViewModel())
        .padding()
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
}
