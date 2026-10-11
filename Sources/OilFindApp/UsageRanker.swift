import Foundation
import OilFindCore

/// Only the bounded candidate set is reordered. The core result is immutable.
enum UsageRanker {
    static let normalPrefixLimit = 200
    private struct Candidate {
        let key: SearchPresentation.RowKey
        let source: SearchSource
        let id: UInt32
        var position: Int?
        var exact: Bool
        var sameQuery: Bool
        var bonus: Int
        var lastUsed: Date
    }
    private static func exactName(_ id: UInt32, store: IndexStore, query: Query) -> Bool {
        let name = store.nameBytes(id)
        return query.clauses.contains { clause in
            clause.alternatives.contains { atom in
                guard !atom.negated else { return false }
                let needle: [UInt8], sensitive: Bool
                switch atom.matcher {
                case .name(let bytes, let exactCase): needle = bytes; sensitive = exactCase
                case .fileName(let bytes), .folderName(let bytes): needle = bytes; sensitive = false
                default: return false
                }
                if !sensitive && (needle.contains(where: { $0 >= 128 }) || name.contains(where: { $0 >= 128 })) {
                    // Strings are confined to the bounded ranking candidates.
                    return String(decoding: name, as: UTF8.self).caseInsensitiveCompare(String(decoding: needle, as: UTF8.self)) == .orderedSame
                }
                return needle.count == name.count && needle.enumerated().allSatisfy { i, byte in
                    let value = name[i]
                    return sensitive ? byte == value : byte == (value >= 65 && value <= 90 ? value + 32 : value)
                }
            }
        }
    }
    @discardableResult
    static func rank(_ presentation: SearchPresentation, history: [ResolvedUsage], favorites: [URL] = [],
                     options: SearchOptions, context: String, now: Date = Date(), cancelled: @escaping () -> Bool = { false }) -> Int {
        guard options.sort == .relevance, !cancelled(), !history.isEmpty || !favorites.isEmpty else { return 0 }
        let query = presentation.query
        let atoms = query.clauses.flatMap(\.alternatives)
        var candidates: [SearchPresentation.RowKey: Candidate] = [:]
        var recentKeys: Set<SearchPresentation.RowKey> = []
        // Only resolve bounded paths; all filesystem work was completed by the caller.
        for source in presentation.sources where source.isOnline {
            let relevant = history.filter { $0.availability == .available && $0.record.launches > 0 && $0.record.identity?.sourceID == source.id }
            Searcher.withEntryPredicates(atoms, options: options, in: source.store, isCancelled: cancelled) { predicate in
                Searcher.withDirectoryScope(options.directoryScope, in: source.store) { inScope in
                    func eligible(_ id: UInt32) -> Bool {
                        guard inScope(id), options.kind == nil || source.store.kind[Int(id)] == options.kind else { return false }
                        var offset = 0
                        for clause in query.clauses {
                            let matches = clause.alternatives.indices.contains { index in
                                let matched = predicate(offset + index, id)
                                return clause.alternatives[index].negated ? !matched : matched
                            }
                            if !matches { return false }; offset += clause.alternatives.count
                        }
                        return true
                    }
                    func candidate(_ url: URL, record: UsageRecord?) {
                        guard !cancelled(), source.store.hashReady, let id = source.store.resolve(path: url.path), eligible(id) else { return }
                        let key = SearchPresentation.RowKey(sourceID: source.id, id: id)
                        let exact = exactName(id, store: source.store, query: query)
                        let age = max(0, now.timeIntervalSince(record?.lastUsed ?? .distantPast))
                        let frequency = min(12, record?.launches ?? 0)
                        let recency = age < 3600 ? 8 : age < 86400 ? 6 : age < 604800 ? 3 : 0
                        let bonus = min(24, frequency + recency + (record?.context == context ? 4 : 0) + (record == nil ? 4 : 0))
                        let old = candidates[key]
                        candidates[key] = Candidate(key: key, source: source, id: id, position: old?.position, exact: exact,
                            sameQuery: record?.queries.contains(query.raw) == true || old?.sameQuery == true,
                            bonus: max(bonus, old?.bonus ?? 0), lastUsed: max(record?.lastUsed ?? .distantPast, old?.lastUsed ?? .distantPast))
                        if record != nil { recentKeys.insert(key) }
                    }
                    for value in relevant { candidate(value.url, record: value.record) }
                    if !query.isEmpty { for url in favorites.prefix(UsageStore.candidateLimit) { candidate(url, record: nil) } }
                }
            }
        }
        guard !candidates.isEmpty, !cancelled() else { return 0 }
        // Nonempty promotion requires membership in the original complete NAME match set,
        // not supplementary hits. A partial snapshot cannot promise complete traversal.
        if !query.isEmpty {
            let complete = presentation.single.map { $0.items.count == $0.total }
                ?? presentation.multiple.map { $0.items.count == $0.total } ?? false
            guard complete else { return 0 }
        }
        let wanted = Dictionary(grouping: candidates.keys, by: \.sourceID).mapValues { Set($0.map(\.id)) }
        var memberKeys: Set<SearchPresentation.RowKey> = []
        // Locate all wanted IDs in one pass without materializing a path per match.
        // Relevance supplements append rows, so core positions remain unchanged.
        func locate(_ id: UInt32, sourceID: String, position: Int) {
            let key = SearchPresentation.RowKey(sourceID: sourceID, id: id)
            memberKeys.insert(key)
            candidates[key]?.position = position
        }
        if let single = presentation.single, let ids = wanted["startup"] {
            for (position, id) in single.items.enumerated() {
                if position % 4096 == 0 && cancelled() { return 0 }
                if ids.contains(id) { locate(id, sourceID: "startup", position: position) }
            }
        } else if let multiple = presentation.multiple {
            let sourceIDs = multiple.sources.map(\.id)
            let ids = sourceIDs.map { wanted[$0] ?? [] }
            for (position, hit) in multiple.items.enumerated() {
                if position % 4096 == 0 && cancelled() { return 0 }
                if ids[hit.sourceIndex].contains(hit.entryID) { locate(hit.entryID, sourceID: sourceIDs[hit.sourceIndex], position: position) }
            }
        }
        if query.isEmpty && presentation.hasSupplements {
            let coreCount = presentation.single?.items.count ?? presentation.multiple!.items.count
            for position in coreCount..<presentation.count {
                guard let row = presentation.baseRow(position), wanted[row.source.id]?.contains(row.id) == true else { continue }
                locate(row.id, sourceID: row.source.id, position: position)
            }
        }
        if !query.isEmpty { candidates = candidates.filter { memberKeys.contains($0.key) } }
        guard !candidates.isEmpty else { return 0 }
        let coreSortedCount = presentation.single?.sortedCount ?? presentation.multiple!.sortedCount
        let prefix = query.isEmpty ? 0 : min(normalPrefixLimit, coreSortedCount, presentation.count)
        for position in 0..<prefix {
            guard let row = presentation.baseRow(position) else { continue }
            let key = SearchPresentation.RowKey(sourceID: row.source.id, id: row.id)
            if candidates[key] == nil {
                let exact = row.source.store.read { exactName(row.id, store: row.source.store, query: query) }
                candidates[key] = Candidate(key: key, source: row.source, id: row.id, position: position,
                    exact: exact, sameQuery: false, bonus: 0, lastUsed: .distantPast)
            }
        }
        let sorted = candidates.values.sorted { a, b in
            if !query.isEmpty {
                if a.exact != b.exact { return a.exact }
                if a.sameQuery != b.sameQuery { return a.sameQuery }
                if a.bonus != b.bonus { return a.bonus > b.bonus }
            } else if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            if a.position != b.position { return (a.position ?? Int.max) < (b.position ?? Int.max) }
            return a.key.sourceID == b.key.sourceID ? a.id < b.id : a.key.sourceID < b.key.sourceID
        }
        let positions = sorted.compactMap(\.position)
        let extra = query.isEmpty ? sorted.filter { $0.position == nil }.map { (source: $0.source, id: $0.id) } : []
        var extraIndex = 0
        let order = sorted.map { candidate -> Int in
            if let position = candidate.position { return position }
            extraIndex += 1; return -extraIndex
        }
        presentation.applyPersonalPrefix(positions, recent: extra, order: order)
        presentation.markRecent(recentKeys)
        return presentation.personalPrefixCount
    }
}
