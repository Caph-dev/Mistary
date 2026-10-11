import Foundation
import Combine
import OilFindCore

struct UsageRecord: Codable, Identifiable {
    enum Activity: String, Codable { case initiated, navigated, copied }
    let id: UUID
    let type: ActionItemType
    let identity: HistoryIdentity?
    // Web records contain only a keyword ID, never the URL or query body.
    let keywordID: String?
    var activity: Activity
    var count: Int
    var lastUsed: Date
    var queries: [String]
    var context: String
    var launches: Int
}

struct ResolvedUsage {
    let record: UsageRecord
    let url: URL
    let availability: DirectoryAvailability
}

/// Main-thread owner; queries receive immutable records and resolve them on the search queue.
final class UsageStore: ObservableObject {
    static let shared = UsageStore(url: ProductIdentity.dataDirectory().appendingPathComponent("usage.json"))
    static let recordLimit = 1000
    static let candidateLimit = 200
    private struct Document: Codable { let version: Int; let enabled: Bool; let records: [UsageRecord] }
    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var enabled = true
    @Published private(set) var error: Error?
    private(set) var epoch: UInt64 = 0
    private(set) var revision: UInt64 = 0
    let system: HistorySystem
    private let url: URL?
    private let clock: () -> Date
    private var seen: Set<UUID> = []
    private var writable = true
    enum StoreError: Error { case invalidDocument }

    init(url: URL?, system: HistorySystem = HistorySystem(), clock: @escaping () -> Date = Date.init) {
        self.url = url; self.system = system; self.clock = clock
        guard let url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 16_777_216 else { throw StoreError.invalidDocument }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1, doc.records.count <= Self.recordLimit,
                  Set(doc.records.map(\.id)).count == doc.records.count,
                  doc.records.allSatisfy({ $0.count > 0 && $0.count <= 1_000_000 && $0.launches >= 0 && $0.launches <= $0.count && $0.queries.count <= 8 && $0.queries.allSatisfy { $0.utf8.count <= 512 } && ($0.type == .web ? $0.identity == nil && $0.keywordID != nil && $0.queries.isEmpty : $0.identity?.path.hasPrefix("/") == true) }) else { throw StoreError.invalidDocument }
            records = doc.records; enabled = doc.enabled
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError { self.error = error; writable = false }
        }
    }
    private func save(_ records: [UsageRecord], enabled: Bool) throws {
        guard writable else { throw StoreError.invalidDocument }
        do {
            if let url {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(Document(version: 1, enabled: enabled, records: records)).write(to: url, options: .atomic)
            }
            self.records = records; self.enabled = enabled; revision &+= 1; error = nil
        } catch { self.error = error; throw error }
    }
    func setEnabled(_ value: Bool) throws {
        guard enabled != value else { return }
        epoch &+= 1; try save(records, enabled: value)
    }
    func clear() throws {
        epoch &+= 1; seen.removeAll()
        // Explicit deletion also recovers an unreadable history document.
        writable = true; try save([], enabled: enabled)
    }
    @discardableResult
    func record(actionID: UUID, epoch captured: UInt64?, type: ActionItemType, url: URL?, sourceID: String,
                expected: FileIdentity? = nil, keywordID: String? = nil, activity: UsageRecord.Activity,
                query: String, context: String) -> Bool {
        guard enabled, captured == epoch, !seen.contains(actionID) else { return false }
        let identity = url.flatMap { system.capture($0, sourceID: sourceID, expected: expected) }
        guard type == .web ? keywordID != nil : identity != nil else { return false }
        seen.insert(actionID)
        // Action IDs are transient and bounded separately from persisted target records.
        if seen.count > 4096 { seen = [actionID] }
        var updated = records
        let position = updated.firstIndex { record in
            guard record.activity == activity else { return false }
            if type == .web { return record.keywordID == keywordID && record.type == .web }
            guard record.type == type, let old = record.identity, let identity else { return false }
            return old.sameObject(as: identity)
        }
        let previous = position.map { updated.remove(at: $0) }
        var queries = previous?.queries ?? []
        if type != .web, activity != .copied, !query.isEmpty, query.utf8.count <= 512 {
            queries.removeAll { $0 == query }; queries.insert(query, at: 0); queries = Array(queries.prefix(8))
        }
        let record = UsageRecord(id: previous?.id ?? UUID(), type: type, identity: identity, keywordID: keywordID,
            activity: activity, count: min(1_000_000, (previous?.count ?? 0) + 1), lastUsed: clock(), queries: queries,
            context: String(context.prefix(256)), launches: min(1_000_000, (previous?.launches ?? 0) + (activity == .copied ? 0 : 1)))
        updated.insert(record, at: 0)
        do { try save(Array(updated.prefix(Self.recordLimit)), enabled: enabled); return true }
        catch { return false }
    }
    static func resolve(_ records: [UsageRecord], system: HistorySystem, sources: [SearchSource],
                        cancelled: () -> Bool = { false }) -> [ResolvedUsage] {
        var result: [ResolvedUsage] = []
        let candidates = Array(records.lazy.filter { $0.launches > 0 && $0.activity != .copied && $0.identity != nil }.prefix(candidateLimit))
        let needed = Set(candidates.compactMap { $0.identity?.sourceID })
        let roots = Dictionary(uniqueKeysWithValues: sources.filter { $0.isOnline && needed.contains($0.id) }.map { source in
            let indexed = source.store.read { source.store.rootPath }
            return (source.id, (indexed: indexed, canonical: URL(fileURLWithPath: indexed).resolvingSymlinksInPath().path))
        })
        for record in candidates {
            if cancelled() { break }
            guard let identity = record.identity else { continue }
            guard let source = sources.first(where: { $0.id == identity.sourceID }), source.isOnline else {
                result.append(ResolvedUsage(record: record, url: URL(fileURLWithPath: identity.path), availability: .offline)); continue
            }
            let resolved = system.resolve(identity)
            var url = resolved.0
            if resolved.1 == .available, let root = roots[source.id], root.indexed != root.canonical,
               url.path == root.canonical || url.path.hasPrefix(root.canonical == "/" ? "/" : root.canonical + "/") {
                let mapped = URL(fileURLWithPath: root.indexed + url.path.dropFirst(root.canonical.count))
                if identity.matches(mapped, system: system) { url = mapped }
            }
            result.append(ResolvedUsage(record: record, url: url, availability: resolved.1))
        }
        return result
    }
}
