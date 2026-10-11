import SwiftUI

/// Replayable, data-driven product tour. Settings is its only host today;
/// there is deliberately no first-launch persistence or root-level routing.
struct AppJourneyView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    let steps: [AppJourneyStep]
    private let onClose: (() -> Void)?
    private let onCompletion: (() -> Void)?

    @State private var currentIndex = 0
    @State private var carouselPosition: CGFloat = 0
    @State private var isTransitioning = false
    @State private var isVisible = false
    @AccessibilityFocusState private var isCaptionFocused: Bool

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
        ZStack(alignment: .top) {
            TexturedDarkBackground(variant: .sidebar)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                journeyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                footer
            }

            header
        }
        .preferredColorScheme(.dark)
        .onAppear {
            currentIndex = 0
            carouselPosition = 0
            isTransitioning = false
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
    }

    private var currentStep: AppJourneyStep? {
        guard steps.indices.contains(currentIndex) else { return nil }
        return steps[currentIndex]
    }

    private var journeyContent: some View {
        GeometryReader { geometry in
            let phoneHeight = min(max(1, geometry.size.height - 190), 620,
                                  geometry.size.width * 0.66 * 1266 / 585)
            let phoneWidth = phoneHeight * 585 / 1266
            let pose = currentStep?.phonePose ?? AppJourneyPhonePose()

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    JourneyPhoneFrame(
                        steps: steps,
                        position: carouselPosition,
                        reduceMotion: reduceMotion)
                    .frame(width: phoneWidth, height: phoneHeight)
                    .scaleEffect(reduceMotion ? 1 : pose.scale)
                    .offset(y: reduceMotion ? 0 : phoneHeight * pose.verticalOffset)
                    .frame(maxWidth: .infinity)
                    .frame(height: phoneHeight + 60)
                    .clipped()
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.95),
                                .init(color: .clear, location: 1),
                            ], startPoint: .top, endPoint: .bottom)
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)

                    ZStack(alignment: .top) {
                        if let step = currentStep {
                            JourneyCaption(step: step)
                                .id(step.id)
                                .transition(captionTransition)
                        } else {
                            Text("App Journey is unavailable.")
                                .foregroundStyle(Color.appSecondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 108, alignment: .top)
                    .padding(.top, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(currentStep.map {
                        "Page \(currentIndex + 1) of \(steps.count). \($0.title). \($0.description)"
                    } ?? "App Journey is unavailable.")
                    .accessibilityFocused($isCaptionFocused)

                    Spacer(minLength: 12)
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
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
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: currentIndex)
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

    private var captionTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: JourneyCaptionMotion(blur: 8, opacity: 0),
                identity: JourneyCaptionMotion(blur: 0, opacity: 1))
                .animation(.easeOut(duration: 0.30).delay(0.18)),
            removal: .modifier(
                active: JourneyCaptionMotion(blur: 8, opacity: 0),
                identity: JourneyCaptionMotion(blur: 0, opacity: 1))
                .animation(.easeOut(duration: 0.16)))
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

        isTransitioning = true
        isCaptionFocused = false
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.20)
            : .timingCurve(0.22, 0.80, 0.24, 1, duration: 0.64)

        withAnimation(animation, completionCriteria: .removed) {
            currentIndex = nextIndex
            carouselPosition = CGFloat(nextIndex)
        } completion: {
            guard isVisible else { return }
            isTransitioning = false
            isCaptionFocused = true
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

private struct JourneyPhoneFrame: View {
    let steps: [AppJourneyStep]
    let position: CGFloat
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let bezel = width * 0.018
            let radius = width * 0.14

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.black)

                GeometryReader { screen in
                    ZStack {
                        // The moving screens share one stationary clipping boundary and bezel.
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            Image(step.imageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: screen.size.width, height: screen.size.height)
                                .clipped()
                                .modifier(JourneyScreenMotion(
                                    distance: CGFloat(index) - position,
                                    travel: screen.size.width,
                                    reduceMotion: reduceMotion))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius - bezel, style: .continuous))
                .padding(bezel)

                Capsule()
                    .fill(.black)
                    .frame(width: width * 0.25, height: height * 0.025)
                    .overlay(alignment: .trailing) {
                        Circle()
                            .fill(Color.white.opacity(0.06))
                            .frame(width: width * 0.019, height: width * 0.019)
                            .padding(.trailing, width * 0.018)
                    }
                    .padding(.top, height * 0.018)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.75), .white.opacity(0.18),
                                     .white.opacity(0.48), .white.opacity(0.20)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: max(0.8, width * 0.004))
            }
            .overlay(alignment: .leading) {
                VStack(spacing: height * 0.025) {
                    sideButton(height: height * 0.028)
                    sideButton(height: height * 0.055)
                    sideButton(height: height * 0.055)
                }
                .offset(x: -2, y: -height * 0.20)
            }
            .overlay(alignment: .trailing) {
                sideButton(height: height * 0.085)
                    .offset(x: 2, y: -height * 0.16)
            }
            .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
        }
    }

    private func sideButton(height: CGFloat) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0.40), .black],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 2, height: height)
    }
}

private struct JourneyCaption: View {
    let step: AppJourneyStep

    var body: some View {
        VStack(spacing: 7) {
            Text(step.title)
                .font(.custom("EBGaramond-Regular", size: 30, relativeTo: .title))
                .foregroundStyle(Color.appPrimaryText)

            Text(step.description)
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Color.appSecondaryText)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 520)
        .padding(.horizontal, 30)
    }
}

private struct JourneyScreenMotion: AnimatableModifier {
    var distance: CGFloat
    let travel: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { distance }
        set { distance = newValue }
    }

    func body(content: Content) -> some View {
        content
            .offset(x: reduceMotion ? 0 : distance * travel)
            .opacity(reduceMotion ? Double(max(0, 1 - abs(distance))) : 1)
    }
}

private struct JourneyCaptionMotion: ViewModifier {
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: blur).opacity(opacity)
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
