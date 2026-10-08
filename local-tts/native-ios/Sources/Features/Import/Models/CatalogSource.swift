import Foundation

struct CatalogSource: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case builtIn
        case custom
    }

    let id: String
    let name: String
    let url: URL
    let kind: Kind

    var isCustom: Bool { kind == .custom }

    var subtitle: String {
        switch id {
        case "project-gutenberg":
            return "Free public-domain books from Project Gutenberg"
        case "standard-ebooks":
            return "Carefully produced public-domain editions"
        default:
            return url.host() ?? url.absoluteString
        }
    }

    static let builtIns: [CatalogSource] = [
        CatalogSource(
            id: "project-gutenberg",
            name: "Project Gutenberg",
            url: URL(string: "https://www.gutenberg.org/ebooks/")!,
            kind: .builtIn),
        CatalogSource(
            id: "standard-ebooks",
            name: "Standard Ebooks",
            url: URL(string: "https://standardebooks.org/ebooks")!,
            kind: .builtIn),
    ]
}

enum CatalogSourceValidationError: LocalizedError, Equatable {
    case emptyName
    case invalidURL
    case secureURLRequired
    case duplicateURL

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name for this catalog."
        case .invalidURL:
            return "Enter a valid catalog website address."
        case .secureURLRequired:
            return "Catalogs must use a secure HTTPS address."
        case .duplicateURL:
            return "This catalog has already been added."
        }
    }
}

struct CatalogDownloadedBook {
    let fileURL: URL
    let format: BookImportFormat
    let displayName: String
}
