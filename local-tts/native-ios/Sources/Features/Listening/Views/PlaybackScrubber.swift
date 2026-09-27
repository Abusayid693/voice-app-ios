import SwiftUI

/// A thin, Music-style progress bar with a small round knob — deliberately
/// not a `Slider`, whose stock thumb is a large circle that dominates a
/// transport this compact. Drag anywhere along it (the hit target is much
/// taller than the visible track) and the track thickens slightly while in
/// hand, which is the only affordance it needs.
struct PlaybackScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Fires true when a drag begins and false when it ends, matching
    /// `Slider`'s own `onEditingChanged` contract so the caller can pause
    /// its clock while the knob is held.
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    private let trackHeight: CGFloat = 4
    private let draggingTrackHeight: CGFloat = 7
    private let knobSize: CGFloat = 11

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = isDragging ? draggingTrackHeight : trackHeight
            let knobX = min(max(width * fraction, knobSize / 2), width - knobSize / 2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.appPrimaryText.opacity(0.22))
                    .frame(height: height)
                Capsule()
                    .fill(Color.appPrimaryText.opacity(0.85))
                    .frame(width: max(0, width * fraction), height: height)
                Circle()
                    .fill(Color.appPrimaryText)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: knobX - knobSize / 2)
            }
            .frame(maxHeight: .infinity)
            // The visible track is a few points tall; the draggable area is
            // the full 28pt row, so the knob doesn't demand a precise hit.
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = self.value(at: drag.location.x, width: width)
                    }
                    .onEnded { drag in
                        value = self.value(at: drag.location.x, width: width)
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 28)
    }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return range.lowerBound }
        let clamped = min(max(x / width, 0), 1)
        return range.lowerBound + Double(clamped) * (range.upperBound - range.lowerBound)
    }
}

#Preview {
    struct Harness: View {
        @State private var value: Double = 40
        var body: some View {
            PlaybackScrubber(value: $value, range: 0...120, onEditingChanged: { _ in })
                .padding(28)
                .background(Color.appBackground)
        }
    }
    return Harness()
}
