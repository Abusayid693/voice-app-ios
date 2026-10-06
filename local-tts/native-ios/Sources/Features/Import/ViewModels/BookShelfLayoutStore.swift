import Combine
import Foundation

/// Shelf-only placement; Library's date sorting and import identities stay unchanged.
@MainActor
final class BookShelfLayoutStore: ObservableObject {
    @Published private(set) var rows: [[UUID]]
    @Published private(set) var titles: [String]
    @Published var errorMessage: String?
    private let fileURL: URL
    private var needsPersistence: Bool

    private struct StoredLayout: Codable {
        let rows: [[UUID]]
        let titles: [String]
    }

    private static let suggestedTitles = [
        "Quiet Corners", "Paper Trails", "Next Chapters", "Hidden Gems",
        "Moonlit Reads", "Old Favorites", "Weekend Stories", "Slow Mornings",
        "The Long List", "Stories to Keep", "Unhurried Pages", "New Worlds",
    ]

    init(fileURL: URL = SavedGeneration.baseDirectory.appendingPathComponent("shelf-layout.json")) {
        self.fileURL = fileURL
        let data = try? Data(contentsOf: fileURL)
        if let stored = data.flatMap({ try? JSONDecoder().decode(StoredLayout.self, from: $0) }) {
            rows = stored.rows
            titles = stored.titles
            needsPersistence = false
        } else {
            // Backward compatibility with the original rows-only JSON payload.
            let legacyRows = data.flatMap { try? JSONDecoder().decode([[UUID]].self, from: $0) } ?? []
            rows = legacyRows
            titles = Self.makeSuggestedTitles(count: max(legacyRows.count, 3), excluding: [])
            needsPersistence = true
        }
    }

    /// Keep intentional empty shelves. New reservations append, never fill old gaps.
    func layout(for orderedIDs: [UUID]) -> [[UUID]] {
        let valid = Set(orderedIDs)
        var seen = Set<UUID>()
        var result = rows.map { row in
            row.filter { valid.contains($0) && seen.insert($0).inserted }
        }
        for id in orderedIDs where seen.insert(id).inserted {
            let last = result.lastIndex(where: { !$0.isEmpty }) ?? 0
            while result.count <= last { result.append([]) }
            result[last].append(id)
        }
        while result.count > 3 && result.last?.isEmpty == true { result.removeLast() }
        while result.count < 3 { result.append([]) }
        return result
    }

    func synchronize(_ orderedIDs: [UUID]) {
        let updated = layout(for: orderedIDs)
        let updatedTitles = normalizedTitles(for: updated.count)
        guard needsPersistence || updated != rows || updatedTitles != titles else { return }
        _ = persist(rows: updated, titles: updatedTitles)
    }

    /// Called only on release. Shelves have no capacity limit or automatic overflow.
    @discardableResult
    func move(_ id: UUID, to shelf: Int, before nextID: UUID?, orderedIDs: [UUID]) -> Bool {
        var updated = layout(for: orderedIDs)
        guard orderedIDs.contains(id), updated.indices.contains(shelf) else { return false }
        for index in updated.indices { updated[index].removeAll { $0 == id } }
        let insertion = nextID.flatMap { updated[shelf].firstIndex(of: $0) } ?? updated[shelf].count
        updated[shelf].insert(id, at: insertion)
        return persist(rows: updated, titles: normalizedTitles(for: updated.count))
    }

    func title(for shelf: Int) -> String {
        titles.indices.contains(shelf) ? titles[shelf] : "Shelf \(shelf + 1)"
    }

    @discardableResult
    func renameShelf(at shelf: Int, to proposedTitle: String) -> Bool {
        guard rows.indices.contains(shelf) else { return false }
        let title = String(proposedTitle
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .prefix(40))
        guard !title.isEmpty else { return false }
        var updatedTitles = normalizedTitles(for: rows.count)
        guard updatedTitles[shelf] != title else { return true }
        updatedTitles[shelf] = title
        return persist(rows: rows, titles: updatedTitles)
    }

    private func normalizedTitles(for count: Int) -> [String] {
        var result = Array(titles.prefix(count))
        guard result.count < count else { return result }
        result.append(contentsOf: Self.makeSuggestedTitles(
            count: count - result.count, excluding: Set(result)))
        return result
    }

    private static func makeSuggestedTitles(count: Int, excluding existing: Set<String>) -> [String] {
        var available = suggestedTitles.filter { !existing.contains($0) }.shuffled()
        var used = existing
        var result: [String] = []
        while result.count < count {
            let candidate: String
            if available.isEmpty {
                var number = 1
                while used.contains("Shelf \(number)") { number += 1 }
                candidate = "Shelf \(number)"
            } else {
                candidate = available.removeFirst()
            }
            used.insert(candidate)
            result.append(candidate)
        }
        return result
    }

    private func persist(rows updatedRows: [[UUID]], titles updatedTitles: [String]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(StoredLayout(rows: updatedRows, titles: updatedTitles))
                .write(to: fileURL, options: .atomic)
            rows = updatedRows
            titles = updatedTitles
            needsPersistence = false
            return true
        } catch {
            errorMessage = "Couldn't save the shelf arrangement. Please try again."
            return false
        }
    }
}
