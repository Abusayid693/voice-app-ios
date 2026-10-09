import SwiftUI
import UIKit

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
                    AboutScreenshotMarquee()
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

private struct AboutScreenshotMarquee: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AboutScreenshotMarqueeRepresentable(reduceMotion: reduceMotion)
        .frame(height: AboutScreenshotMarqueeView.viewportHeight)
        .clipped()
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App preview gallery")
    }
}

private struct AboutScreenshotMarqueeRepresentable: UIViewRepresentable {
    let reduceMotion: Bool

    func makeUIView(context: Context) -> AboutScreenshotMarqueeView {
        let view = AboutScreenshotMarqueeView()
        view.setReduceMotion(reduceMotion)
        return view
    }

    func updateUIView(_ uiView: AboutScreenshotMarqueeView, context: Context) {
        uiView.setReduceMotion(reduceMotion)
    }
}

private final class AboutScreenshotMarqueeView: UIView {
    static let cardHeight: CGFloat = 286 * 0.9
    static let viewportHeight: CGFloat = cardHeight + 36

    private static let assets = [
        "AboutPreviewShelf",
        "AboutPreviewBookDetail",
        "AboutPreviewReader",
        "AboutPreviewNowPlaying",
        "AboutPreviewStats",
        "AboutPreviewLibrary",
    ]
    private static let cardWidth: CGFloat = 132 * 0.9
    private static let spacing: CGFloat = 14
    private static let cornerRadius: CGFloat = 22 * 0.9
    private static let loopWidth = CGFloat(assets.count) * (cardWidth + spacing)
    private static let animationKey = "about.screenshot-marquee.translation"

    private let trackView = UIView()
    private var reduceMotion = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        trackView.backgroundColor = .clear
        trackView.isUserInteractionEnabled = false
        addSubview(trackView)
        buildCards()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackView.frame = CGRect(
            x: 0,
            y: (bounds.height - Self.cardHeight) / 2,
            width: Self.loopWidth * 2,
            height: Self.cardHeight)
        startAnimationIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            trackView.layer.removeAnimation(forKey: Self.animationKey)
        } else {
            setNeedsLayout()
            layoutIfNeeded()
            startAnimationIfNeeded()
        }
    }

    func setReduceMotion(_ enabled: Bool) {
        guard reduceMotion != enabled || trackView.layer.animation(forKey: Self.animationKey) == nil else {
            return
        }
        reduceMotion = enabled
        trackView.layer.removeAnimation(forKey: Self.animationKey)
        trackView.layer.transform = CATransform3DIdentity
        if !enabled {
            startAnimationIfNeeded()
        }
    }

    private func buildCards() {
        for sequence in 0..<2 {
            for (index, asset) in Self.assets.enumerated() {
                let x = CGFloat(sequence * Self.assets.count + index)
                    * (Self.cardWidth + Self.spacing)
                let card = UIView(frame: CGRect(
                    x: x,
                    y: 0,
                    width: Self.cardWidth,
                    height: Self.cardHeight))
                card.isUserInteractionEnabled = false
                card.layer.shadowColor = UIColor.black.cgColor
                card.layer.shadowOpacity = 0.14
                card.layer.shadowRadius = 12
                card.layer.shadowOffset = CGSize(width: 0, height: 7)
                card.layer.shadowPath = UIBezierPath(
                    roundedRect: card.bounds,
                    cornerRadius: Self.cornerRadius).cgPath

                let imageView = UIImageView(frame: card.bounds)
                imageView.image = UIImage(named: asset)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = Self.cornerRadius
                imageView.layer.cornerCurve = .continuous
                imageView.layer.borderColor = UIColor.black.withAlphaComponent(0.10).cgColor
                imageView.layer.borderWidth = 0.75
                card.addSubview(imageView)
                trackView.addSubview(card)
            }
        }
    }

    private func startAnimationIfNeeded() {
        guard window != nil,
              !reduceMotion,
              trackView.layer.animation(forKey: Self.animationKey) == nil
        else { return }

        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -Self.loopWidth
        animation.duration = 48
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = true
        trackView.layer.add(animation, forKey: Self.animationKey)
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
