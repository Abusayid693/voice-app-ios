import Hugeicons
import LucideSwift
import SwiftUI
import UIKit

/// Settings navigation hosted by Home's leading drawer.
struct SettingsSheet: View {
    @ObservedObject var viewModel: TTSViewModel
    let previewPlayer: VoicePreviewPlayer
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isVoiceLibraryPresented = false
    @State private var isStoragePresented = false
    @State private var isAboutPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer(minLength: 0)
                        closeButton
                    }

                    Text("Make it yours")
                        .font(.custom("EBGaramond-Regular", size: 52, relativeTo: .largeTitle))
                        .foregroundStyle(Color.appPrimaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 4)

                    VStack(spacing: 12) {
                        NavigationLink {
                            SetupView(viewModel: viewModel, packs: viewModel.packs)
                                .toolbar(.visible, for: .navigationBar)
                        } label: {
                            row(title: "Setup", icon: .circleArrowDown)
                        }
                        NavigationLink {
                            VoicePacksView(viewModel: viewModel, packs: viewModel.packs)
                                .toolbar(.visible, for: .navigationBar)
                        } label: {
                            row(title: "Voice Packs", icon: .packageIcon)
                        }
                        Button {
                            isStoragePresented = true
                        } label: {
                            row(title: "Storage", icon: .hardDrive)
                        }
                        Button {
                            isAboutPresented = true
                        } label: {
                            row(title: "About", icon: .info)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 34)

                    Button { isVoiceLibraryPresented = true } label: {
                        voiceGallery
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 30)
                    .accessibilityHint("Opens Voice Library")

                    OpenSourceCard()
                        .padding(.top, 32)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .background { TexturedDarkBackground(variant: .sidebar).ignoresSafeArea() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $isVoiceLibraryPresented) {
            VoiceSettingsSheet(
                viewModel: viewModel,
                packs: viewModel.packs,
                previewPlayer: previewPlayer,
                onVoiceSelected: { viewModel.setDefaultKokoroVoice($0) })
        }
        .sheet(isPresented: $isStoragePresented) {
            StorageView(packs: viewModel.packs)
        }
        .fullScreenCover(isPresented: $isAboutPresented) {
            AboutView()
        }
    }

    private var voiceGallery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("YOUR VOICE")
                .font(.system(size: 13, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(Color.appSecondaryText)

            HStack(spacing: -24) {
                ForEach(Array(galleryVoices.enumerated()), id: \.element.id) { index, voice in
                    let distance = abs(index - 3)

                    Image(VoiceCoverArt.assetName(for: voice.code))
                        .resizable()
                        .scaledToFill()
                        .frame(width: gallerySize(for: distance), height: gallerySize(for: distance))
                        .clipShape(Circle())
                        .overlay {
                            if distance != 0 {
                                Circle()
                                    .strokeBorder(
                                        Color.appPrimaryText.opacity(0.16),
                                        lineWidth: 0.75)
                            }
                        }
                        .shadow(
                            color: .black.opacity(distance == 0 ? 0.34 : 0.20),
                            radius: distance == 0 ? 14 : 7,
                            y: 4)
                        .opacity(galleryOpacity(for: distance))
                        .zIndex(Double(4 - distance))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 94, alignment: .center)

            Text(VoiceDisplayName.forCode(viewModel.kokoroVoice))
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color.appPrimaryText)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Your voice, \(VoiceDisplayName.forCode(viewModel.kokoroVoice))")
    }

    private var galleryVoices: [Voice] {
        let voices = VoiceCatalog.allVoices
        guard !voices.isEmpty else { return [] }
        let selectedIndex = voices.firstIndex { $0.code == viewModel.kokoroVoice } ?? 0

        return (-3...3).map { offset in
            let index = (selectedIndex + offset + voices.count) % voices.count
            return voices[index]
        }
    }

    private func gallerySize(for distance: Int) -> CGFloat {
        switch distance {
        case 0: return 92
        case 1: return 76
        case 2: return 62
        default: return 50
        }
    }

    private func galleryOpacity(for distance: Int) -> Double {
        switch distance {
        case 0: return 1
        case 1: return 0.90
        case 2: return 0.74
        default: return 0.58
        }
    }

    /// Capsule rows with the icon trailing, so the titles form one clean left
    /// column and the icons another on the right.
    private func row(title: String, icon: LucideIconName) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 19))
                .foregroundStyle(Color.appPrimaryText.opacity(0.88))
            Spacer(minLength: 12)
            LucideIcon(icon, size: 20, color: Color.appPrimaryText.opacity(0.7))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: Capsule())
        .contentShape(Capsule())
    }

    private var closeButton: some View {
        Button(action: close) {
            Hugeicons.arrowRightDouble.image()
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color.appPrimaryText)
                .frame(width: 19, height: 19)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .modifier(SettingsGlassCircle())
        .accessibilityLabel("Close Settings")
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

/// Real Liquid Glass with its local highlight and press response on iOS 26; a
/// material circle with ordinary button feedback below that.
private struct SettingsGlassCircle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

/// UIKit owns the drawer motion — transform, blur and panel all animate as
/// layer properties inside one interruptible `UIViewPropertyAnimator`, so none
/// of it costs a SwiftUI re-render per frame.
struct SettingsDrawerPresentation<Content: View>: UIViewControllerRepresentable {
    let viewModel: TTSViewModel
    let previewPlayer: VoicePreviewPlayer
    @Binding var isPresented: Bool
    let isEdgeSwipeEnabled: Bool
    let content: Content

    final class Coordinator {
        var previousPresentation: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> SettingsDrawerController<Content> {
        SettingsDrawerController(
            viewModel: viewModel,
            previewPlayer: previewPlayer,
            content: content)
    }

    func updateUIViewController(_ controller: SettingsDrawerController<Content>, context: Context) {
        let presentationChanged = context.coordinator.previousPresentation.map {
            $0 != isPresented
        } ?? false
        context.coordinator.previousPresentation = isPresented

        // A presentation-only update does not alter Home. Replacing its hosting root on either
        // boundary can briefly relayout the fixed bottom chrome.
        if !presentationChanged {
            controller.updateContent(content)
        }
        controller.onPresentationChanged = { value in
            if isPresented != value { isPresented = value }
        }
        controller.updatePresentation(isPresented: isPresented, edgeSwipeEnabled: isEdgeSwipeEnabled)
    }

    static func dismantleUIViewController(_ controller: SettingsDrawerController<Content>, coordinator: ()) {
        controller.tearDown()
    }
}

final class SettingsDrawerController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    var onPresentationChanged: ((Bool) -> Void)?

    private let viewModel: TTSViewModel
    private let previewPlayer: VoicePreviewPlayer
    private let mainController: UIHostingController<Content>
    /// Carries the scale and the blur. Deliberately **not** the live Home.
    ///
    /// Transforming a `UIHostingController`'s view changes its frame in window
    /// coordinates, so UIKit recomputes its `safeAreaInsets` — SwiftUI then
    /// re-lays-out the shelf against different top insets mid-animation and
    /// snaps it back when the transform returns to identity. That is the jump
    /// from the top on close. Scaling a snapshot instead leaves the live view's
    /// geometry untouched for the whole interaction, so there is nothing to
    /// snap back to.
    private let scaledSurface = UIView()
    private var shelfSnapshot: UIView?
    /// A `UIVisualEffectView` rather than SwiftUI's `.blur(radius:)`. The
    /// modifier re-renders the entire shelf offscreen on every radius change,
    /// which — driven frame by frame through a display link — is what made the
    /// drawer stutter. A visual-effect view composites on the GPU and animates
    /// as a normal property inside the same `UIViewPropertyAnimator` that drives
    /// the transform, so it scrubs with the gesture for free.
    private let shelfBlurView = UIVisualEffectView(effect: nil)
    private let backdropButton = UIButton(type: .custom)
    private let panel = UIView()
    private var settingsController: UIHostingController<SettingsSheet>?
    private var settingsResetWorkItem: DispatchWorkItem?
    private var animator: UIViewPropertyAnimator?
    private var drawerPan: UIPanGestureRecognizer?
    private var edgeSwipeEnabled = false
    private var active = false
    private var dragging = false
    private var dragStartProgress: CGFloat = 0
    private var wantsOpen = false
    private var previousSize = CGSize.zero

    /// Full width. With nothing of Home left exposed there is no backdrop to
    /// tap, so the arrow button and the leftward swipe are the only ways out —
    /// both still work, since the pan recogniser lives on the container rather
    /// than on the uncovered area.
    private var panelWidth: CGFloat { max(view.bounds.width, 1) }
    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    init(viewModel: TTSViewModel, previewPlayer: VoicePreviewPlayer, content: Content) {
        self.viewModel = viewModel
        self.previewPlayer = previewPlayer
        mainController = UIHostingController(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(viewModel:content:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Scaling the hosted shelf exposes this container around its edges.
        // Match the shelf paper so that clearance never becomes a dark frame.
        view.backgroundColor = UIColor(Color.whitePaper)
        view.clipsToBounds = true

        addChild(mainController)
        mainController.view.backgroundColor = .clear
        view.addSubview(mainController.view)
        mainController.didMove(toParent: self)

        // Scale from the physical bottom edge so floating chrome does not travel vertically
        // and then appear to jump into place at the end of an interactive close.
        scaledSurface.layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        scaledSurface.backgroundColor = .clear
        scaledSurface.isUserInteractionEnabled = false
        scaledSurface.isHidden = true
        view.addSubview(scaledSurface)

        shelfBlurView.isUserInteractionEnabled = false
        scaledSurface.addSubview(shelfBlurView)

        backdropButton.backgroundColor = .clear
        backdropButton.isHidden = true
        backdropButton.accessibilityLabel = "Close Settings"
        backdropButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(backdropButton)

        panel.layer.cornerRadius = 28
        panel.layer.cornerCurve = .continuous
        panel.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        panel.clipsToBounds = true
        panel.accessibilityElementsHidden = true
        view.addSubview(panel)
        mountSettings()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        drawerPan = pan
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != previousSize else { return }
        let interrupted = animator != nil || dragging
        let destination = dragging ? visibleProgress >= 0.5 : wantsOpen
        previousSize = view.bounds.size
        stopAnimation()
        dragging = false
        mainController.view.frame = view.bounds
        scaledSurface.transform = .identity
        scaledSurface.bounds = CGRect(origin: .zero, size: view.bounds.size)
        scaledSurface.layer.position = CGPoint(x: view.bounds.midX, y: view.bounds.maxY)
        shelfSnapshot?.frame = scaledSurface.bounds
        shelfBlurView.frame = scaledSurface.bounds
        backdropButton.frame = view.bounds
        panel.transform = .identity
        panel.frame = CGRect(x: 0, y: 0, width: panelWidth, height: view.bounds.height)
        settingsController?.view.frame = panel.bounds
        applyEndpoint(open: destination)
        if interrupted {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.animator == nil, !self.dragging else { return }
                self.finish(open: destination)
            }
        }
    }

    /// Blocked only during an active drag, where a SwiftUI relayout would land
    /// between gesture frames. It used to be blocked for the drawer's whole
    /// lifetime, which froze Home — import progress and shelf changes were
    /// dropped while Settings was open and then snapped in on close.
    func updateContent(_ content: Content) {
        guard !dragging else { return }
        mainController.rootView = content
    }

    func updatePresentation(isPresented: Bool, edgeSwipeEnabled: Bool) {
        self.edgeSwipeEnabled = edgeSwipeEnabled
        loadViewIfNeeded()
        guard isPresented != active else { return }
        if isPresented {
            // Layout is stable before the first animated frame.
            view.layoutIfNeeded()
            beginPresentation()
            prepareInteractiveAnimation(at: 0)
            settle(open: true, velocity: 0)
        } else if wantsOpen {
            close()
        }
    }

    private func mountSettings() {
        let controller = UIHostingController(rootView: SettingsSheet(
            viewModel: viewModel,
            previewPlayer: previewPlayer,
            onClose: { [weak self] in self?.close() }))
        controller.overrideUserInterfaceStyle = .dark
        controller.view.backgroundColor = .clear
        addChild(controller)
        panel.addSubview(controller.view)
        controller.view.frame = panel.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.didMove(toParent: self)
        settingsController = controller
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === drawerPan else { return false }
        if active { return true }
        let start = touch.location(in: view)
        return edgeSwipeEnabled && start.x >= 0 && start.x <= 44 && view.bounds.contains(start)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Shelf pans wait for a valid edge opening; touches outside the edge are rejected immediately.
        gestureRecognizer === drawerPan && !active && edgeSwipeEnabled
            && otherGestureRecognizer is UIPanGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              view.window != nil, mainController.presentedViewController == nil,
              settingsController?.presentedViewController == nil
        else { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        if !active {
            return edgeSwipeEnabled && velocity.x > 0
        }
        // Leave rightward back-navigation to the Settings navigation stack at the open endpoint.
        return active && (visibleProgress < 0.99 || velocity.x < 0)
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            let progress = active ? visibleProgress : 0
            dragging = true
            beginPresentation()
            dragStartProgress = progress
            prepareInteractiveAnimation(at: progress)
        case .changed:
            let progress = dragStartProgress + pan.translation(in: view).x / panelWidth
            animator?.fractionComplete = min(max(progress, 0), 1)
        case .ended:
            dragging = false
            let progress = animator?.fractionComplete ?? dragStartProgress
            let velocity = pan.velocity(in: view).x
            // Two snap points: closed and open. A flick takes precedence over the midpoint.
            let open = abs(velocity) > 350 ? velocity > 0 : progress > 0.5
            settle(open: open, velocity: velocity)
        case .cancelled, .failed:
            dragging = false
            settle(open: dragStartProgress >= 0.5, velocity: 0)
        default:
            break
        }
    }

    private func beginPresentation() {
        guard !active else { return }
        settingsResetWorkItem?.cancel()
        settingsResetWorkItem = nil
        installShelfSnapshot()
        active = true
        backdropButton.isHidden = false
        mainController.view.accessibilityElementsHidden = true
        panel.accessibilityElementsHidden = false
        panel.accessibilityViewIsModal = true
        onPresentationChanged?(true)
    }

    private var visibleProgress: CGFloat {
        if let animator {
            if dragging || !animator.isRunning {
                return animator.fractionComplete
            }
            if let translation = panel.layer.presentation()?.transform.m41 {
                return min(max(1 + translation / panelWidth, 0), 1)
            }
            // The animation's model layer already contains its destination. On the first
            // display-link tick, fall back to the actual fraction instead of jumping there.
            return animator.fractionComplete
        }
        if reduceMotion {
            return panel.layer.presentation().map { CGFloat($0.opacity) } ?? panel.alpha
        }
        let translation = panel.layer.presentation()?.transform.m41 ?? panel.transform.tx
        return min(max(1 + translation / panelWidth, 0), 1)
    }

    private func prepareInteractiveAnimation(at progress: CGFloat) {
        stopAnimation()
        applyEndpoint(open: false)
        let animation = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 1) { [weak self] in
            self?.applyEndpoint(open: true)
        }
        animation.scrubsLinearly = true
        animation.addCompletion { [weak self, weak animation] position in
            guard let self, let animation, self.animator === animation else { return }
            self.animator = nil
            self.finish(open: position == .end)
        }
        animator = animation
        animation.startAnimation()
        animation.pauseAnimation()
        animation.fractionComplete = progress
    }

    private func settle(open: Bool, velocity: CGFloat) {
        wantsOpen = open
        guard let animator else { return }
        let remaining = (open ? 1 : 0) - animator.fractionComplete
        if abs(remaining) < 0.001 {
            stopAnimation()
            applyEndpoint(open: open)
            finish(open: open)
            return
        }
        animator.isReversed = !open
        let relativeVelocity = min(max(velocity / (remaining * panelWidth), -8), 8)
        let timing = UISpringTimingParameters(
            dampingRatio: 1,
            initialVelocity: CGVector(dx: relativeVelocity, dy: 0))
        animator.continueAnimation(withTimingParameters: timing, durationFactor: reduceMotion ? 0.6 : 1)
    }

    private func applyEndpoint(open: Bool) {
        panel.transform = reduceMotion || open ? .identity : CGAffineTransform(translationX: -panelWidth, y: 0)
        panel.alpha = reduceMotion && !open ? 0 : 1
        scaledSurface.transform = open && !reduceMotion
            ? CGAffineTransform(scaleX: 0.96, y: 0.96) : .identity
        // Animatable inside the property animator, and scrubs with it.
        shelfBlurView.effect = open && !reduceMotion
            ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
    }

    @objc private func close() {
        guard active else { return }
        let progress = visibleProgress
        dragging = false
        prepareInteractiveAnimation(at: progress)
        settle(open: false, velocity: 0)
    }

    private func finish(open: Bool) {
        resolveEndpoint(open: open)
        // Hand the screen back to the live view the moment the drawer is fully
        // closed. Leaving the capture up would leave Home looking like a frozen
        // screenshot — and because the live view never moved, swapping back is
        // pixel-identical rather than a jump.
        if !open { teardownShelfSnapshot() }
        active = open
        wantsOpen = open
        backdropButton.isHidden = !open
        mainController.view.accessibilityElementsHidden = open
        panel.accessibilityElementsHidden = !open
        panel.accessibilityViewIsModal = open
        onPresentationChanged?(open)
        if open {
            UIAccessibility.post(notification: .screenChanged, argument: settingsController?.view)
        } else {
            scheduleSettingsReset()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    /// Rebuilding a NavigationStack can be expensive. Do it after the close transition rather
    /// than on its final frame, while retaining the fresh-root behavior for the next opening.
    private func scheduleSettingsReset() {
        settingsResetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.active, self.animator == nil, !self.dragging else { return }
            self.settingsController?.willMove(toParent: nil)
            self.settingsController?.view.removeFromSuperview()
            self.settingsController?.removeFromParent()
            self.mountSettings()
            self.settingsResetWorkItem = nil
        }
        settingsResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Captures Home and hands the capture to `scaledSurface`, which is what
    /// actually scales and blurs. The live view then holds still underneath at
    /// full size with its alpha dropped — alpha costs no layout, so its safe
    /// area and scroll position survive the whole interaction untouched.
    private func installShelfSnapshot() {
        guard !reduceMotion else { return }
        teardownShelfSnapshot()
        guard let snapshot = mainController.view.snapshotView(afterScreenUpdates: false) else {
            return
        }
        snapshot.frame = scaledSurface.bounds
        snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        snapshot.isUserInteractionEnabled = false
        scaledSurface.insertSubview(snapshot, belowSubview: shelfBlurView)
        shelfSnapshot = snapshot
        scaledSurface.isHidden = false
        mainController.view.alpha = 0
    }

    private func teardownShelfSnapshot() {
        shelfSnapshot?.removeFromSuperview()
        shelfSnapshot = nil
        scaledSurface.isHidden = true
        mainController.view.alpha = 1
    }

    /// Interactive reversals can finish between sampled frames. Resolve every visual property
    /// to its exact endpoint so a slow closing gesture cannot leave Home fractionally scaled.
    private func resolveEndpoint(open: Bool) {
        UIView.performWithoutAnimation {
            scaledSurface.layer.removeAllAnimations()
            shelfBlurView.layer.removeAllAnimations()
            panel.layer.removeAllAnimations()
            applyEndpoint(open: open)
        }
    }

    private func stopAnimation() {
        animator?.stopAnimation(true)
        animator = nil
    }

    override func accessibilityPerformEscape() -> Bool {
        guard active else { return false }
        close()
        return true
    }

    func tearDown() {
        stopAnimation()
        settingsResetWorkItem?.cancel()
        settingsResetWorkItem = nil
        if let drawerPan { view.removeGestureRecognizer(drawerPan) }
        drawerPan = nil
        scaledSurface.transform = .identity
        shelfBlurView.effect = nil
        teardownShelfSnapshot()
    }
}

#Preview {
    let dependencies = DependencyContainer()
    SettingsSheet(
        viewModel: TTSViewModel(dependencies: dependencies),
        previewPlayer: VoicePreviewPlayer(),
        onClose: nil)
}
