import Foundation
import Combine

struct FavoriteDirectory: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var bookmark: Data?
    var fallbackPath: String
    var sourceID: String?
}

struct FavoriteSystem {
    var bookmark: (URL) throws -> Data = { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    var resolve: (Data) throws -> URL = { data in
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    var check: (URL) -> DirectoryAvailability = { url in
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isReadableKey])
            guard values.isDirectory == true else { return .missing }
            return values.isReadable == false ? .permission : .available
        } catch {
            let error = error as NSError
            return error.code == NSFileReadNoPermissionError ? .permission : .missing
        }
    }
}

enum DirectoryAvailability: String { case available, unindexed, offline, missing, permission }

/// Filesystem and bookmark operations must be called outside index locks.
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore(url: ProductIdentity.dataDirectory().appendingPathComponent("favorites.json"))
    private struct Document: Codable { let version: Int; let favorites: [FavoriteDirectory] }
    enum StoreError: Error { case unknownVersion, unreadableDocument, unavailableDirectory }
    @Published private(set) var favorites: [FavoriteDirectory] = []
    @Published private(set) var error: Error?
    private let url: URL?
    let system: FavoriteSystem
    private var writable = true
    init(url: URL?, system: FavoriteSystem = FavoriteSystem()) {
        self.url = url; self.system = system
        guard let url else { return }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
            guard document.version == 1 else { throw StoreError.unknownVersion }
            guard Set(document.favorites.map(\.id)).count == document.favorites.count,
                  document.favorites.allSatisfy({ $0.fallbackPath.hasPrefix("/") }) else { throw StoreError.unreadableDocument }
            favorites = document.favorites
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError { self.error = error; writable = false }
        }
    }
    private func save(_ updated: [FavoriteDirectory]) throws {
        guard writable else { throw StoreError.unreadableDocument }
        do {
            if let url {
                let data = try JSONEncoder().encode(Document(version: 1, favorites: updated))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            favorites = updated; error = nil
        } catch { self.error = error; throw error }
    }
    @discardableResult func add(_ directory: URL, name: String? = nil, sourceID: String? = nil) throws -> UUID {
        let url = directory.standardizedFileURL
        guard url.isFileURL, system.check(url) == .available else { throw StoreError.unavailableDirectory }
        if let existing = favorites.first(where: { $0.fallbackPath == url.path }) { return existing.id }
        let id = UUID()
        let entry = FavoriteDirectory(id: id, name: name ?? url.lastPathComponent, bookmark: try? system.bookmark(url), fallbackPath: url.path, sourceID: sourceID)
        try save(favorites + [entry]); return id
    }
    func rename(_ id: UUID, to name: String) throws {
        var updated = favorites
        guard let i = updated.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updated[i].name = name; try save(updated)
    }
    func move(_ id: UUID, by offset: Int) throws {
        var updated = favorites
        guard let i = updated.firstIndex(where: { $0.id == id }), updated.indices.contains(i + offset) else { return }
        updated.swapAt(i, i + offset); try save(updated)
    }
    func remove(_ id: UUID) throws { try save(favorites.filter { $0.id != id }) }
    func resolve(_ entry: FavoriteDirectory) -> (URL, DirectoryAvailability) {
        let url = entry.bookmark.flatMap { try? system.resolve($0) } ?? URL(fileURLWithPath: entry.fallbackPath, isDirectory: true)
        guard url.isFileURL else { return (URL(fileURLWithPath: entry.fallbackPath), .missing) }
        return (url.standardizedFileURL, system.check(url))
    }
}
