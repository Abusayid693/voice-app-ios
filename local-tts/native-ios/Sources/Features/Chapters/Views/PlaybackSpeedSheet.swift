import SwiftUI

enum PlaybackRateFormatter {
    static func string(_ rate: Double) -> String {
        let rounded = rate.rounded()
        if abs(rate - rounded) < 0.001 { return "\(Int(rounded))×" }
        return String(format: "%.1f×", rate)
    }
}

struct PlaybackSpeedSheet: View {
    @Binding var rate: Double
    let chromeTheme: ReaderChromeTheme

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        InteractiveGlassBottomSheet(
            theme: chromeTheme,
            detents: [.height(340)],
            closeAccessibilityLabel: "Close playback speed",
            contentTopInset: 78,
            onClose: { dismiss() }
        ) { headerInset in
            HStack(alignment: .center, spacing: 18) {
                VStack(spacing: 18) {
                    Text(speedCharacter)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(chromeTheme.primaryText)

                    stepControls
                    presets
                }

                VerticalSpeedSlider(
                    value: $rate,
                    range: BookAudioPlayer.minimumPlaybackRate...BookAudioPlayer.maximumPlaybackRate,
                    accessibilityStep: 0.1,
                    track: chromeTheme.controlBackground,
                    fill: chromeTheme.accent)
                    .frame(width: 54, height: 226)
            }
            .padding(.horizontal, 18)
            .padding(.top, headerInset)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var stepControls: some View {
        HStack(spacing: 16) {
            stepButton(systemName: "minus", label: "Decrease speed", delta: -0.1)

            Text(PlaybackRateFormatter.string(rate))
                .font(.system(size: 43, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(chromeTheme.primaryText)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText(value: rate))
                .animation(.snappy(duration: 0.22), value: rate)

            stepButton(systemName: "plus", label: "Increase speed", delta: 0.1)
        }
    }

    private func stepButton(systemName: String, label: String, delta: Double) -> some View {
        Button {
            rate = stepped(rate + delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(chromeTheme.primaryText)
                .frame(width: 52, height: 52)
                .background(chromeTheme.controlBackground, in: Circle())
        }
        .buttonStyle(PlaybackSpeedPressStyle())
        .disabled(delta < 0
            ? rate <= BookAudioPlayer.minimumPlaybackRate
            : rate >= BookAudioPlayer.maximumPlaybackRate)
        .opacity((delta < 0
            ? rate <= BookAudioPlayer.minimumPlaybackRate
            : rate >= BookAudioPlayer.maximumPlaybackRate) ? 0.4 : 1)
        .accessibilityLabel(label)
    }

    private var presets: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(BookAudioPlayer.presetPlaybackRates, id: \.self) { preset in
                Button {
                    rate = preset
                } label: {
                    Text(PlaybackRateFormatter.string(preset))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(chromeTheme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(chromeTheme.controlBackground, in: Capsule())
                }
                .buttonStyle(PlaybackSpeedPressStyle())
                .accessibilityLabel("\(PlaybackRateFormatter.string(preset)) speed")
            }
        }
    }

    private var speedCharacter: String {
        switch rate {
        case ..<0.8: "Slow"
        case ..<1.0: "Relaxed"
        case ..<1.2: "Narrate"
        case ..<1.5: "Smooth"
        case ..<2.0: "Brisk"
        case ..<2.5: "Fast"
        default: "Very Fast"
        }
    }

    private func stepped(_ value: Double) -> Double {
        min(max((value * 10).rounded() / 10, BookAudioPlayer.minimumPlaybackRate),
            BookAudioPlayer.maximumPlaybackRate)
    }

}

private struct VerticalSpeedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let accessibilityStep: Double
    let track: Color
    let fill: Color

    var body: some View {
        GeometryReader { proxy in
            let progress = normalizedProgress

            ZStack(alignment: .bottom) {
                Capsule().fill(track)
                UnevenRoundedRectangle(
                    topLeadingRadius: 5,
                    bottomLeadingRadius: proxy.size.width / 2,
                    bottomTrailingRadius: proxy.size.width / 2,
                    topTrailingRadius: 5,
                    style: .continuous)
                    .fill(fill)
                    .frame(height: proxy.size.height * progress)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = min(max(gesture.location.y, 0), proxy.size.height)
                        let progress = 1 - position / max(proxy.size.height, 1)
                        let raw = range.lowerBound
                            + Double(progress) * (range.upperBound - range.lowerBound)
                        value = clamped(raw)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Playback speed")
        .accessibilityValue(PlaybackRateFormatter.string(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = stepped(value + accessibilityStep)
            case .decrement: value = stepped(value - accessibilityStep)
            @unknown default: break
            }
        }
    }

    private var normalizedProgress: CGFloat {
        CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    private func stepped(_ raw: Double) -> Double {
        let rounded = ((raw - range.lowerBound) / accessibilityStep).rounded()
            * accessibilityStep + range.lowerBound
        return clamped(rounded)
    }

    private func clamped(_ raw: Double) -> Double {
        min(max(raw, range.lowerBound), range.upperBound)
    }
}

private struct PlaybackSpeedPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.08 : 0)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.08)
                    : .spring(response: 0.22, dampingFraction: 0.72),
                value: configuration.isPressed)
    }
}

#Preview {
    PlaybackSpeedSheet(rate: .constant(1), chromeTheme: .light)
}
