import SwiftUI

/// Full-screen editorial About presentation opened from Settings. The parent
/// drawer remains mounted beneath this native cover, so dismissing returns to
/// the exact Settings position the user left.
struct AboutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var contentRevealed = false

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build)) · Kokoro-ANE"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TexturedLightBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Default sizing matches this view's original bespoke
                    // marquee exactly — see `ScreenshotMarquee`'s own doc
                    // comment for why it moved to DesignSystem.
                    ScreenshotMarquee()
                        .modifier(AboutEntranceReveal(
                            isVisible: contentRevealed,
                            delay: 0))

                    Text(
                        "Import a PDF, EPUB, or text file and turn it into a calm "
                            + "read-along experience. Speech is generated on your device, "
                            + "so your books and listening stay private."
                    )
                    .font(.system(size: 19, weight: .regular, design: .rounded))
                    .foregroundStyle(BookShelfPalette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 28)
                    .padding(.top, 42)
                    .modifier(AboutEntranceReveal(
                        isVisible: contentRevealed,
                        delay: 0.10))

                    makerNote
                        .padding(.horizontal, 24)
                        .padding(.top, 28)
                        .modifier(AboutEntranceReveal(
                            isVisible: contentRevealed,
                            delay: 0.20))

                    SignatureText(
                        "Rehan Chouhdury",
                        isRevealed: contentRevealed,
                        color: BookShelfPalette.primaryText,
                        fontSize: 28,
                        duration: 1.15,
                        delay: 0.30)
                        .frame(width: 210)
                        .frame(maxWidth: 560, alignment: .trailing)
                        .padding(.horizontal, 28)
                        .padding(.top, 14)

                    Text(versionLabel)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(BookShelfPalette.secondaryText.opacity(0.82))
                        .padding(.top, 20)
                        .modifier(AboutEntranceReveal(
                            isVisible: contentRevealed,
                            delay: 0.40))

                    feedbackButton
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .modifier(AboutEntranceReveal(
                            isVisible: contentRevealed,
                            delay: 0.50))
                }
                .padding(.top, 72)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)

            closeButton
                .padding(.top, 10)
                .padding(.trailing, 20)
        }
        .preferredColorScheme(.light)
        .task {
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            contentRevealed = true
        }
        .onDisappear {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { contentRevealed = false }
        }
    }

    private var makerNote: some View {
        VStack(spacing: 16) {
            Text("A NOTE FROM THE MAKER")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(BookShelfPalette.secondaryText)

            Text(
                "Built for moments when your eyes are elsewhere.\n"
                    + "Thank you for making it part of your shelf."
            )
            .font(.system(size: 17, weight: .regular, design: .serif))
            .foregroundStyle(BookShelfPalette.primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
            .allowsTightening(true)
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity)
    }

    private var feedbackButton: some View {
        Button(action: openFeedbackEmail) {
            HStack(spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Share Feedback")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(Color.black, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.pressOpacity)
        .accessibilityHint("Opens your mail app")
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 72, height: 48)
                .background(Color.black, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.pressOpacity)
        .accessibilityLabel("Close About")
    }

    private func openFeedbackEmail() {
        var components = URLComponents(string: "mailto:abusayid693@gmail.com")
        components?.queryItems = [
            URLQueryItem(name: "subject", value: "App feedback"),
            URLQueryItem(
                name: "body",
                value: "Hi Rehan,\n\n\n\n\(versionLabel)"),
        ]
        if let url = components?.url {
            openURL(url)
        }
    }
}

private struct AboutEntranceReveal: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isVisible: Bool
    let delay: TimeInterval

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 14)
            .animation(
                isVisible && !reduceMotion
                    ? .easeOut(duration: 0.44).delay(delay)
                    : nil,
                value: isVisible)
            .allowsHitTesting(reduceMotion || isVisible)
            .accessibilityHidden(!reduceMotion && !isVisible)
    }
}

#Preview {
    AboutView()
}
