import Foundation
import Combine
import OilFindCore

struct SavedFilter: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var query: String
    var sort: String
    var ascending: Bool
    var kind: UInt8?
    var pinyin: Bool
    var scope: String?
    init(id: UUID = UUID(), name: String, query: String, options: SearchOptions) {
        self.id = id; self.name = name; self.query = query
        sort = FilterBar.sortName(options.sort); ascending = options.ascending; kind = options.kind
        pinyin = options.pinyin; scope = options.directoryScope?.path
    }
    var options: SearchOptions? {
        let key: SortKey
        switch sort {
        case "relevance": key = .relevance
        case "name": key = .name
        case "modified": key = .modified
        case "size": key = .size
        default: return nil
        }
        guard kind == nil || kind! <= 8, scope == nil || (scope!.hasPrefix("/") && !scope!.utf8.contains(0)) else { return nil }
        return SearchOptions(sort: key, ascending: ascending, kind: kind, pinyin: pinyin,
                             directoryScope: scope.map { DirectoryScope(path: $0) })
    }
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 256 && query.count <= 16_384
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !query.utf8.contains(0)
            && options != nil && Query.parse(query).diagnostics.isEmpty
    }
    func parse(now: Date = Date(), store: IndexStore? = nil) throws -> Query {
        guard isValid else { throw SavedFiltersStore.StoreError.invalidFilter }
        let parsed = Query.parse(query, now: now, store: store)
        guard parsed.diagnostics.isEmpty else { throw SavedFiltersStore.StoreError.invalidFilter }
        return parsed
    }
}

final class SavedFiltersStore: ObservableObject {
    static let shared = SavedFiltersStore(url: ProductIdentity.dataDirectory().appendingPathComponent("filters.json"))
    private struct Document: Codable { let version: Int; let filters: [SavedFilter] }
    enum StoreError: Error { case invalidDocument, invalidFilter, unavailableScope }
    @Published private(set) var filters: [SavedFilter] = []
    @Published private(set) var error: Error?
    private let url: URL?
    private var writable = true
    init(url: URL?) {
        self.url = url
        guard let url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_048_576 else { throw StoreError.invalidDocument }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1, Self.valid(doc.filters) else { throw StoreError.invalidDocument }
            filters = doc.filters
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError { self.error = error; writable = false }
        }
    }
    private static func valid(_ filters: [SavedFilter]) -> Bool {
        filters.count <= 128 && Set(filters.map(\.id)).count == filters.count && filters.allSatisfy(\.isValid)
    }
    func set(_ updated: [SavedFilter]) throws {
        guard writable, Self.valid(updated) else { throw StoreError.invalidDocument }
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Document(version: 1, filters: updated)).write(to: url, options: .atomic)
            }
            filters = updated; error = nil
        } catch { self.error = error; throw error }
    }
}
