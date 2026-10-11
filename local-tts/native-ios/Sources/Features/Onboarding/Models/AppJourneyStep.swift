import Foundation

/// Offset is a fraction of the phone's unscaled height.
struct AppJourneyPhonePose: Hashable {
    var scale: Double = 1
    var verticalOffset: Double = 0
}

/// One configurable page in the replayable App Journey.
struct AppJourneyStep: Identifiable, Hashable {
    let id: Int
    let imageName: String
    let title: String
    let description: String
    var phonePose = AppJourneyPhonePose()

    static let appJourney: [AppJourneyStep] = [
        AppJourneyStep(
            id: 1,
            imageName: "Journey1",
            title: "Build your shelf",
            description: "Import PDF, EPUB, or text files and keep every book arranged in one calm place."
        ),
        AppJourneyStep(
            id: 2,
            imageName: "Journey2",
            title: "Meet every book",
            description: "Review its details and choose whether to read or listen.",
            phonePose: AppJourneyPhonePose(scale: 1.12, verticalOffset: 0.04)
        ),
        AppJourneyStep(
            id: 3,
            imageName: "Journey3",
            title: "Read along",
            description: "Follow each spoken word and personalize the page, text, and playback.",
            phonePose: AppJourneyPhonePose(scale: 1.28, verticalOffset: -0.12)
        ),
        AppJourneyStep(
            id: 4,
            imageName: "Journey4",
            title: "Listen anywhere",
            description: "Continue hands-free with your chosen voice and playback speed."
        ),
        AppJourneyStep(
            id: 5,
            imageName: "Journey5",
            title: "See your reading grow",
            description: "Track daily minutes, completed pages, and your reading streak.",
            phonePose: AppJourneyPhonePose(scale: 1.22, verticalOffset: 0.10)
        ),
        AppJourneyStep(
            id: 6,
            imageName: "Journey6",
            title: "Find your way back",
            description: "Filter your library and resume any book from where you stopped.",
            phonePose: AppJourneyPhonePose(scale: 1.06, verticalOffset: 0.02)
        ),
    ]
}
