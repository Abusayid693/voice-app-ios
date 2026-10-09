import Combine
import Foundation

@MainActor
final class CatalogSourceStore: ObservableObject {
    @Published private(set) var customSources: [CatalogSource]

    private static let storageKey = "tools.customCatalogSources.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CatalogSource].self, from: data)
        {
            customSources = decoded.filter(\.isCustom)
        } else {
            customSources = []
        }
    }

    var allSources: [CatalogSource] {
        CatalogSource.builtIns + customSources
    }

    @discardableResult
    func add(name: String, address: String) -> Result<CatalogSource, CatalogSourceValidationError> {
        let normalizedName = name
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedName.isEmpty else { return .failure(.emptyName) }

        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else { return .failure(.invalidURL) }
        let candidate = trimmedAddress.contains("://")
            ? trimmedAddress
            : "https://\(trimmedAddress)"

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased()
        else { return .failure(.invalidURL) }
        guard scheme == "https" else { return .failure(.secureURLRequired) }
        guard let host = components.host, !host.isEmpty else { return .failure(.invalidURL) }

        components.scheme = "https"
        components.host = host.lowercased()
        components.fragment = nil
        guard let url = components.url else { return .failure(.invalidURL) }

        let normalizedURL = Self.comparisonKey(for: url)
        guard !allSources.contains(where: { Self.comparisonKey(for: $0.url) == normalizedURL })
        else { return .failure(.duplicateURL) }

        let source = CatalogSource(
            id: UUID().uuidString,
            name: String(normalizedName.prefix(50)),
            url: url,
            kind: .custom)
        customSources.append(source)
        persist()
        return .success(source)
    }

    func delete(_ source: CatalogSource) {
        guard source.isCustom else { return }
        customSources.removeAll { $0.id == source.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(customSources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func comparisonKey(for url: URL) -> String {
        url.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}
