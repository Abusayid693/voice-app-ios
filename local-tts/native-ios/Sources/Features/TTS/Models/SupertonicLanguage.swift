import Foundation

/// Supertonic-3's 31 languages + its `"na"` (language-agnostic) mode, from
/// `Supertonic3Constants.availableLanguages`. No Chinese — Kokoro's Mandarin
/// variant stays the answer there.
///
/// A data table rather than an enum-with-switch like `KokoroVariant`/
/// `PocketLanguage`, which don't scale well past a handful of cases.
struct SupertonicLanguage: Identifiable, Hashable, Codable, Sendable {
    /// The exact ISO code `Supertonic3Manager.synthesize(language:)` expects.
    let code: String
    let displayName: String
    let flag: String

    var id: String { code }

    static let `default` = SupertonicLanguage(code: "en", displayName: "English", flag: "🇺🇸")

    static let all: [SupertonicLanguage] = [
        .default,
        SupertonicLanguage(code: "ko", displayName: "Korean", flag: "🇰🇷"),
        SupertonicLanguage(code: "ja", displayName: "Japanese", flag: "🇯🇵"),
        SupertonicLanguage(code: "ar", displayName: "Arabic", flag: "🇸🇦"),
        SupertonicLanguage(code: "bg", displayName: "Bulgarian", flag: "🇧🇬"),
        SupertonicLanguage(code: "cs", displayName: "Czech", flag: "🇨🇿"),
        SupertonicLanguage(code: "da", displayName: "Danish", flag: "🇩🇰"),
        SupertonicLanguage(code: "de", displayName: "German", flag: "🇩🇪"),
        SupertonicLanguage(code: "el", displayName: "Greek", flag: "🇬🇷"),
        SupertonicLanguage(code: "es", displayName: "Spanish", flag: "🇪🇸"),
        SupertonicLanguage(code: "et", displayName: "Estonian", flag: "🇪🇪"),
        SupertonicLanguage(code: "fi", displayName: "Finnish", flag: "🇫🇮"),
        SupertonicLanguage(code: "fr", displayName: "French", flag: "🇫🇷"),
        SupertonicLanguage(code: "hi", displayName: "Hindi", flag: "🇮🇳"),
        SupertonicLanguage(code: "hr", displayName: "Croatian", flag: "🇭🇷"),
        SupertonicLanguage(code: "hu", displayName: "Hungarian", flag: "🇭🇺"),
        SupertonicLanguage(code: "id", displayName: "Indonesian", flag: "🇮🇩"),
        SupertonicLanguage(code: "it", displayName: "Italian", flag: "🇮🇹"),
        SupertonicLanguage(code: "lt", displayName: "Lithuanian", flag: "🇱🇹"),
        SupertonicLanguage(code: "lv", displayName: "Latvian", flag: "🇱🇻"),
        SupertonicLanguage(code: "nl", displayName: "Dutch", flag: "🇳🇱"),
        SupertonicLanguage(code: "pl", displayName: "Polish", flag: "🇵🇱"),
        SupertonicLanguage(code: "pt", displayName: "Portuguese", flag: "🇵🇹"),
        SupertonicLanguage(code: "ro", displayName: "Romanian", flag: "🇷🇴"),
        SupertonicLanguage(code: "ru", displayName: "Russian", flag: "🇷🇺"),
        SupertonicLanguage(code: "sk", displayName: "Slovak", flag: "🇸🇰"),
        SupertonicLanguage(code: "sl", displayName: "Slovenian", flag: "🇸🇮"),
        SupertonicLanguage(code: "sv", displayName: "Swedish", flag: "🇸🇪"),
        SupertonicLanguage(code: "tr", displayName: "Turkish", flag: "🇹🇷"),
        SupertonicLanguage(code: "uk", displayName: "Ukrainian", flag: "🇺🇦"),
        SupertonicLanguage(code: "vi", displayName: "Vietnamese", flag: "🇻🇳"),
        SupertonicLanguage(code: "na", displayName: "Language-agnostic", flag: "🌐"),
    ]
}
