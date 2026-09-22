import SwiftUI

/// The two persistent presentations of the Home tab. Keeping this separate
/// from the app-wide tab selection makes Reading a focused Home experience,
/// rather than a fifth tab with duplicated navigation state.
enum HomeMode: String, CaseIterable, Identifiable {
    case studio
    case reading

    var id: String { rawValue }

    var title: String {
        switch self {
        case .studio: "Studio"
        case .reading: "Reading"
        }
    }

    var background: Color {
        switch self {
        case .studio: .appBackground
        case .reading: Color(hex: 0xF5F3ED)
        }
    }

    var primaryText: Color {
        switch self {
        case .studio: .appPrimaryText
        case .reading: Color(hex: 0x171715)
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .studio: .dark
        case .reading: .light
        }
    }
}
