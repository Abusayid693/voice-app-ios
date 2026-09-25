/// A voice plus the presentation context that the catalogue does not own.
/// Shared by voice discovery, selection, and preview surfaces.
struct VoiceTile: Identifiable {
    let id: String
    let voice: Voice
    let engine: Engine
    let engineLabel: String
    let isAvailable: Bool

    var name: String { voice.code }
    var displayName: String { voice.displayName }
    var countryFlag: String { voice.flag }
    var descriptionText: String { voice.tagline ?? engineLabel }
    var longDescription: String {
        voice.longDescription ?? "A distinctive voice with its own character."
    }
}
