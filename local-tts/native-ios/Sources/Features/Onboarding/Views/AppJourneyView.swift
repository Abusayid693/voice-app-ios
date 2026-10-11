import SwiftUI

/// Replayable, data-driven product tour. Settings is its only host today;
/// there is deliberately no first-launch persistence or root-level routing.
struct AppJourneyView: View {
    private enum Direction {
        case forward
        case backward

        var sign: CGFloat { self == .forward ? 1 : -1 }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    let steps: [AppJourneyStep]
    private let onClose: (() -> Void)?
    private let onCompletion: (() -> Void)?

    @State private var currentIndex = 0
    @State private var direction = Direction.forward
    @State private var isTransitioning = false
    @State private var unlockTask: Task<Void, Never>?

    init(
        steps: [AppJourneyStep] = AppJourneyStep.appJourney,
        onClose: (() -> Void)? = nil,
        onCompletion: (() -> Void)? = nil
    ) {
        self.steps = steps
        self.onClose = onClose
        self.onCompletion = onCompletion
    }

    var body: some View {
        ZStack {
            TexturedDarkBackground(variant: .sidebar)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ZStack {
                    if let step = currentStep {
                        AppJourneyPage(step: step)
                            .id(step.id)
                            .transition(pageTransition)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(
                                "Page \(currentIndex + 1) of \(steps.count). "
                                    + "\(step.title). \(step.description)"
                            )
                    } else {
                        Text("App Journey is unavailable.")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.appSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                footer
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            currentIndex = 0
            direction = .forward
            isTransitioning = false
        }
        .onDisappear {
            unlockTask?.cancel()
            unlockTask = nil
        }
    }

    private var currentStep: AppJourneyStep? {
        guard steps.indices.contains(currentIndex) else { return nil }
        return steps[currentIndex]
    }

    private var header: some View {
        HStack {
            Button { move(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressOpacity)
            .modifier(JourneyGlassCircle())
            .opacity(currentIndex == 0 ? 0 : 1)
            .disabled(currentIndex == 0 || isTransitioning)
            .accessibilityHidden(currentIndex == 0)
            .accessibilityLabel("Previous journey page")

            Spacer(minLength: 0)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appPrimaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressOpacity)
            .modifier(JourneyGlassCircle())
            .accessibilityLabel("Close App Journey")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(spacing: 15) {
            HStack(spacing: 7) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(
                            index == currentIndex
                                ? Color.appPrimaryText
                                : Color.appPrimaryText.opacity(0.24)
                        )
                        .frame(width: index == currentIndex ? 20 : 6, height: 6)
                }
            }
            .animation(.easeOut(duration: 0.22), value: currentIndex)
            .frame(height: 10)
            .accessibilityHidden(true)

            Button(action: continueJourney) {
                Text(isLastPage ? "Done" : "Continue")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primaryButtonText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.primaryButtonBackground, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.pressOpacity)
            .disabled(isTransitioning)
            .accessibilityHint(isLastPage ? "Closes App Journey" : "Shows the next feature")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var isLastPage: Bool {
        steps.isEmpty || currentIndex == steps.count - 1
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        let sign = direction.sign
        return .asymmetric(
            insertion: .modifier(
                active: JourneyPageMotion(horizontalOffset: 180 * sign, rotation: -14 * sign),
                identity: JourneyPageMotion(horizontalOffset: 0, rotation: 0)
            ),
            removal: .modifier(
                active: JourneyPageMotion(horizontalOffset: -180 * sign, rotation: 14 * sign),
                identity: JourneyPageMotion(horizontalOffset: 0, rotation: 0)
            )
        )
    }

    private func continueJourney() {
        if isLastPage {
            finish()
        } else {
            move(by: 1)
        }
    }

    private func move(by delta: Int) {
        let nextIndex = currentIndex + delta
        guard steps.indices.contains(nextIndex), !isTransitioning else { return }

        direction = delta > 0 ? .forward : .backward
        isTransitioning = true

        let duration = reduceMotion ? 0.20 : 0.52
        let animation: Animation = reduceMotion
            ? .easeOut(duration: duration)
            : .spring(response: duration, dampingFraction: 0.88)

        withAnimation(animation) {
            currentIndex = nextIndex
        }

        unlockTask?.cancel()
        unlockTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            guard !Task.isCancelled else { return }
            isTransitioning = false
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }

    private func finish() {
        if let onCompletion {
            onCompletion()
        } else {
            dismiss()
        }
    }
}

private struct AppJourneyPage: View {
    let step: AppJourneyStep

    private let imageAspectRatio: CGFloat = 585 / 1266

    var body: some View {
        GeometryReader { geometry in
            let targetHeight = min(geometry.size.height * 0.63, 470)
            let cardWidth = min(targetHeight * imageAspectRatio, geometry.size.width - 72)
            let cardHeight = cardWidth / imageAspectRatio

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 12)

                    Image(step.imageName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: cardWidth, height: cardHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                        }
                        .shadow(color: .black.opacity(0.42), radius: 22, y: 12)
                        .accessibilityHidden(true)

                    Text(step.title)
                        .font(.custom("EBGaramond-Regular", size: 30, relativeTo: .title))
                        .foregroundStyle(Color.appPrimaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                        .padding(.top, 22)

                    Text(step.description)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(Color.appSecondaryText)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 520)
                        .padding(.horizontal, 30)
                        .padding(.top, 7)

                    Spacer(minLength: 14)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct JourneyPageMotion: ViewModifier {
    let horizontalOffset: CGFloat
    let rotation: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(horizontalOffset == 0 ? 1 : 0.32)
            .scaleEffect(horizontalOffset == 0 ? 1 : 0.94)
            .rotation3DEffect(
                .degrees(Double(rotation)),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.55
            )
            .offset(x: horizontalOffset)
    }
}

private struct JourneyGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

#Preview {
    AppJourneyView()
}
