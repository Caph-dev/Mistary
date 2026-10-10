import XCTest
import COilFind
@testable import OilFindCore

final class DirectoryScopeTests: XCTestCase {
    private func fixture(outside: Int = 1, inside: Int = 1, root: String = "/", sensitive: Bool = false) -> IndexStore {
        var names = ["", "work", "workspace", "中文"]
        names += (0..<outside).map { "match-out-\($0).txt" }
        names += (0..<inside).map { "match-in-\($0).txt" }
        let records = names.map { Array($0.utf8) }
        let store = IndexStore(rootPath: root, count: names.count, namesLen: records.reduce(0) { $0 + $1.count }, altCount: 0, altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0, caseSensitiveNames: sensitive)
        var offset = 0
        for i in records.indices {
            store.nameOff[i] = UInt32(offset)
            for byte in records[i] { store.names[offset] = byte; offset += 1 }
            store.parent[i] = i < 4 ? 0 : (i < 4 + outside ? 2 : 1)
            store.flags[i] = i < 4 ? SiftFlag.dir | SiftFlag.userArea : SiftFlag.userArea
            store.kind[i] = i < 4 ? 1 : 3; store.depth[i] = i < 4 ? 1 : 2
            store.sizeC[i] = 0; store.mtime[i] = UInt32(names.count - i)
        }
        store.nameOff[names.count] = UInt32(offset); store.altOff[0] = 0
        return store
    }
    private func search(_ store: IndexStore, _ path: String?, text: String = "match", previous: SearchResult? = nil, sort: SortKey = .relevance) throws -> SearchResult {
        try XCTUnwrap(Searcher.search(Query.parse(text), options: SearchOptions(sort: sort, directoryScope: path.map(DirectoryScope.init)), in: store, previous: previous))
    }
    func testBoundaryRootAndMissingScopeBeforeHashReady() throws {
        let store = fixture()
        XCTAssertEqual(try search(store, "/work").items, [5])
        XCTAssertEqual(try search(store, "/work/").items, [5])
        XCTAssertEqual(try search(store, "/workspace/../work/.").items, [5])
        XCTAssertEqual(try search(store, "/workspace").items, [4])
        XCTAssertEqual(try search(store, "/").total, 2)
        XCTAssertEqual(try search(store, nil).items, try search(store, "/").items)
        XCTAssertEqual(try search(store, "/missing").total, 0)
        XCTAssertEqual(try search(store, "relative").total, 0)
        XCTAssertEqual(try search(store, "/work", text: "folder:").items, [1])
    }
    func testVolumeComparisonAndUnicode() throws {
        for sensitive in [false, true] {
            let store = fixture(sensitive: sensitive)
            XCTAssertEqual(try search(store, "/WORK").total, sensitive ? 0 : 1)
            store.buildHash()
            XCTAssertEqual(try search(store, "/WORK").total, sensitive ? 0 : 1)
            XCTAssertEqual(try search(store, "/中文", text: "中文").items, [3])
        }
    }
    func testScopeBeforeRecentLimitAndBatchAndGenericScoring() throws {
        let store = fixture(outside: 300, inside: 220)
        let recent = try search(store, "/work", text: "")
        XCTAssertEqual(recent.total, 200)
        XCTAssertTrue(recent.items.allSatisfy { store.parent[Int($0)] == 1 })
        for query in ["match", "match !absent", "ext:txt", "regex:match", "match | other"] {
            let result = try search(store, "/work", text: query)
            XCTAssertEqual(result.total, 220, query)
            XCTAssertTrue(result.items.allSatisfy { store.parent[Int($0)] == 1 })
        }
    }
    func testLargeResultScopePrecedesTopK() throws {
        let store = fixture(outside: 210_000, inside: 20)
        let all = try search(store, nil, sort: .modified)
        XCTAssertEqual(all.sortedCount, 5000)
        XCTAssertFalse(all.items.prefix(5000).contains(210_004))
        let scoped = try search(store, "/work", previous: all, sort: .modified)
        XCTAssertEqual(scoped.total, 20); XCTAssertEqual(scoped.sortedCount, 20)
        XCTAssertFalse(scoped.isNarrowed)
        XCTAssertEqual(scoped.items.first, 210_004)
    }
    func testCacheAndNarrowingIncludeScopeAndVersion() throws {
        let store = fixture(), cache = SearchCache()
        let all = try search(store, nil); cache.insert(all)
        let options = SearchOptions(directoryScope: DirectoryScope(path: "/work"))
        XCTAssertNil(cache.lookup(query: all.query, options: options, store: store))
        let scoped = try search(store, "/work", previous: all); cache.insert(scoped)
        XCTAssertFalse(scoped.isNarrowed)
        XCTAssertTrue(try search(store, "/work", text: "match-in", previous: scoped).isNarrowed)
        XCTAssertNotNil(cache.lookup(query: all.query, options: options, store: store))
        store.write { store.parent[5] = 2; store.version += 1 }
        XCTAssertNil(cache.lookup(query: all.query, options: options, store: store))
        XCTAssertEqual(try search(store, "/work", previous: scoped).total, 0)
        XCTAssertEqual(try search(fixture(), "/work", previous: scoped).total, 1)
    }
    func testSymlinkAndDeletedDirectoryDoNotEscape() throws {
        let store = fixture()
        store.flags[1] |= SiftFlag.symlink
        XCTAssertEqual(try search(store, "/work").total, 0)
        store.flags[1] = SiftFlag.dir | SiftFlag.deleted
        XCTAssertEqual(try search(store, "/work").total, 0)
    }
    func testPredicatesShareScopeSemantics() {
        let store = fixture(), query = Query.parse("ext:txt")
        Searcher.withEntryPredicates(query.clauses.flatMap(\.alternatives), options: SearchOptions(directoryScope: DirectoryScope(path: "/work")), in: store) { matches in
            XCTAssertFalse(matches(0, 4)); XCTAssertTrue(matches(0, 5))
        }
    }
    func testMutationAndCompactionRecompileDirectoryIdentity() throws {
        let store = fixture()
        store.buildHash()
        let original = try search(store, "/work")
        store.write {
            store.remove(1); store.sweep()
            let replacement = Array("work".utf8).withUnsafeBufferPointer {
                store.insert(parent: 0, name: $0, attrs: EntryAttrs(type: 1))
            }
            Array("match-new.txt".utf8).withUnsafeBufferPointer {
                _ = store.insert(parent: replacement, name: $0, attrs: EntryAttrs(type: 0))
            }
            store.version += 1
        }
        let updated = try search(store, "/work", previous: original)
        XCTAssertFalse(updated.isNarrowed); XCTAssertEqual(updated.total, 1)
        let compacted = store.compacted()
        let after = try search(compacted, "/work", previous: updated)
        XCTAssertFalse(after.isNarrowed); XCTAssertEqual(after.total, 1)
        XCTAssertEqual(compacted.name(after.items[0]), "match-new.txt")
    }
    func testSourceRebindRejectsOldTaskLookupAndInsertion() throws {
        let store = fixture(), cache = SearchCache(), result = try search(store, "/work")
        let online = SearchSource(id: "disk", displayName: "Disk", isOnline: true, store: store)
        let offline = SearchSource(id: "disk", displayName: "Disk", isOnline: false, store: store)
        let oldBinding = cache.bind(to: online)
        cache.insert(result, binding: oldBinding)
        let newBinding = cache.bind(to: offline)
        cache.insert(result, binding: oldBinding)
        XCTAssertNil(cache.lookup(query: result.query, options: result.options, store: store, binding: newBinding))
        cache.insert(result, binding: newBinding)
        XCTAssertNil(cache.lookup(query: result.query, options: result.options, store: store, binding: oldBinding))
        XCTAssertNotNil(cache.lookup(query: result.query, options: result.options, store: store, binding: newBinding))
        cache.removeAll()
        cache.insert(result, binding: newBinding)
        XCTAssertNil(cache.lookup(query: result.query, options: result.options, store: store))
    }
    func testSourceCacheOnlineBindingWithoutPreviousResult() throws {
        let store = fixture(), cache = SearchCache(), query = Query.parse("match")
        let online = SearchSource(id: "disk", displayName: "Disk", isOnline: true, store: store)
        let offline = SearchSource(id: "disk", displayName: "Disk", isOnline: false, store: store)
        let first = try XCTUnwrap(MultiSearcher.search(query, in: [online], caches: ["disk": cache]))
        let cached = try XCTUnwrap(MultiSearcher.search(query, in: [online], caches: ["disk": cache]))
        XCTAssertTrue(first.results[0] === cached.results[0])
        let changed = try XCTUnwrap(MultiSearcher.search(query, in: [offline], caches: ["disk": cache]))
        XCTAssertFalse(changed.results[0] === cached.results[0])
    }
    func testMultipleSourcesResolveIndependentlyIncludingAncestorScope() throws {
        let first = fixture(), second = fixture(root: "/work/nested"), third = fixture(root: "/elsewhere")
        let sources = [SearchSource(id: "a", displayName: "a", isOnline: true, store: first), SearchSource(id: "b", displayName: "b", isOnline: true, store: second), SearchSource(id: "c", displayName: "c", isOnline: false, store: third)]
        let query = Query.parse("match"), options = SearchOptions(directoryScope: DirectoryScope(path: "/work"))
        let result = try XCTUnwrap(MultiSearcher.search(query, options: options, in: sources))
        XCTAssertEqual(result.results.map(\.total), [1, 2, 0])
        let recent = try XCTUnwrap(MultiSearcher.search(Query.parse(""), options: options, in: sources))
        XCTAssertEqual(recent.total, 3)
        let cache = SearchCache(); cache.insert(try search(first, "/work"))
        let offline = [SearchSource(id: "a", displayName: "a", isOnline: false, store: first)]
        let changed = try XCTUnwrap(MultiSearcher.search(query, options: options, in: offline, previous: result, caches: ["a": cache]))
        XCTAssertFalse(changed.results[0].isNarrowed)
    }
}
