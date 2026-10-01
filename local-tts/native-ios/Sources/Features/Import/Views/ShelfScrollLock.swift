import SwiftUI
import UIKit

/// Stops an already-recognized scroll pan as well as disabling future pans during arrangement.
struct ShelfScrollLock: UIViewRepresentable {
    let isLocked: Bool

    func makeUIView(context: Context) -> LockView {
        let view = LockView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: LockView, context: Context) {
        view.isLocked = isLocked
        view.synchronize()
    }

    static func dismantleUIView(_ view: LockView, coordinator: ()) { view.release() }

    final class LockView: UIView {
        var isLocked = false
        private weak var scrollView: UIScrollView?
        private var lockedOffset: CGPoint?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            synchronize()
            // SwiftUI may finish configuring its scroll host after mounting the background.
            DispatchQueue.main.async { [weak self] in self?.synchronize() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            synchronize()
        }

        func synchronize() {
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
            if scrollView !== scroll {
                release()
                scrollView = scroll
            }
            if isLocked {
                if lockedOffset == nil { lockedOffset = scroll.contentOffset }
                scroll.isScrollEnabled = false
                scroll.panGestureRecognizer.isEnabled = false
                if let lockedOffset, scroll.contentOffset != lockedOffset {
                    scroll.setContentOffset(lockedOffset, animated: false)
                }
            } else {
                release()
            }
        }

        func release() {
            guard lockedOffset != nil else { return }
            scrollView?.isScrollEnabled = true
            scrollView?.panGestureRecognizer.isEnabled = true
            lockedOffset = nil
        }
    }
}
