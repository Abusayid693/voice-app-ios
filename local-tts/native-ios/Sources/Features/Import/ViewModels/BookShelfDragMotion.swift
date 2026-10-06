import Combine
import CoreGraphics

/// Only the floating overlay observes finger-rate updates, not the shelf layout.
@MainActor
final class BookShelfDragMotion: ObservableObject {
    @Published var translation: CGSize = .zero
    var location: CGPoint = .zero

    func track(translation: CGSize, location: CGPoint) {
        self.location = location
        if self.translation != translation { self.translation = translation }
    }
}
