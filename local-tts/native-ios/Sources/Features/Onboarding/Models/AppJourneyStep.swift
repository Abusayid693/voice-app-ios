import Foundation

/// One configurable page in the replayable App Journey.
struct AppJourneyStep: Identifiable, Hashable {
    let id: Int
    let imageName: String
    let title: String
    let description: String

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
            description: "Review its details and choose whether to read or listen."
        ),
        AppJourneyStep(
            id: 3,
            imageName: "Journey3",
            title: "Read along",
            description: "Follow each spoken word and personalize the page, text, and playback."
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
            description: "Track daily minutes, completed pages, and your reading streak."
        ),
        AppJourneyStep(
            id: 6,
            imageName: "Journey6",
            title: "Find your way back",
            description: "Filter your library and resume any book from where you stopped."
        ),
    ]
}
