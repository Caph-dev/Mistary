import AppKit
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class SavedFiltersTests: XCTestCase {
    private func filter(query: String = "ext:txt dm:today", scope: String? = nil) -> SavedFilter {
        SavedFilter(name: "Documents", query: query, options: SearchOptions(sort: .modified, ascending: true, kind: 3, pinyin: false,
            directoryScope: scope.map { DirectoryScope(path: $0) }))
    }
    func testRoundTripEditDeleteAndRawQueryPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("filters.json"), f = filter(scope: root.path + "/a/../b/")
        let store = SavedFiltersStore(url: url)
        try store.set([f]); XCTAssertEqual(SavedFiltersStore(url: url).filters, [f])
        XCTAssertEqual(f.query, "ext:txt dm:today"); XCTAssertEqual(f.scope, root.path + "/b")
        var edited = f; edited.name = "Edited"; edited.query = "regex:^report ext:md"
        try store.set([edited]); XCTAssertEqual(SavedFiltersStore(url: url).filters.first?.query, edited.query)
        try store.set([]); XCTAssertTrue(SavedFiltersStore(url: url).filters.isEmpty)
    }
    func testDatesAreReparsedAtActivation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try SavedFiltersStore(url: url).set([filter()])
        let f = try XCTUnwrap(SavedFiltersStore(url: url).filters.first)
        let first = try f.parse(now: Date(timeIntervalSince1970: 1_750_000_000))
        let second = try f.parse(now: Date(timeIntervalSince1970: 1_750_172_800))
        XCTAssertTrue(first.isTimeDependent); XCTAssertTrue(second.isTimeDependent)
        // A file time satisfying one day's query must not satisfy a different day.
        guard case .modified(let range1) = first.clauses.last?.alternatives.first?.matcher,
              case .modified(let range2) = second.clauses.last?.alternatives.first?.matcher else { return XCTFail("Expected date predicates") }
        XCTAssertTrue(range1.contains(range1.lowerBound)); XCTAssertFalse(range2.contains(range1.lowerBound))
    }
    func testEmptyInvalidQueryOptionsAndScopeAreRejected() throws {
        let store = SavedFiltersStore(url: nil)
        for query in ["", "  ", "regex:[", "size:nope", "dm:invalid"] { XCTAssertThrowsError(try store.set([filter(query: query)])) }
        var f = filter(); f.sort = "unknown"; XCTAssertThrowsError(try store.set([f]))
        f = filter(); f.kind = 255; XCTAssertThrowsError(try store.set([f]))
        f = filter(); f.scope = "relative"; XCTAssertThrowsError(try store.set([f]))
    }
    func testCorruptAndOldVersionsCannotOverwritePersistedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("filters.json")
        for text in ["broken", "{\"version\":0,\"filters\":[]}"] {
            let data = Data(text.utf8); try data.write(to: url)
            let store = SavedFiltersStore(url: url)
            XCTAssertNotNil(store.error); XCTAssertThrowsError(try store.set([])); XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
    private func controller() throws -> (URL, IndexStore, SearchViewController) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inside"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("inside/match.txt"))
        try Data().write(to: root.appendingPathComponent("outside.txt"))
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let c = SearchViewController(snapshot: true)
        try c.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0)
        return (root, store, c)
    }
    private func eventually(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return predicate()
    }
    func testActivationFromSaveAndApplicationModesRestoresAllOptionsAndExactScope() throws {
        for mode in [SearchMode.save, .application] {
            let (root, _, c) = try controller(); defer { try? FileManager.default.removeItem(at: root) }
            c.session.setMode(mode)
            let f = filter(query: "txt", scope: root.appendingPathComponent("inside").path)
            try c.activateFilter(f)
            XCTAssertEqual(c.session.context.mode, .ordinary)
            XCTAssertEqual(c.session.directoryScope?.path, f.scope); XCTAssertEqual(c.searchField.text, "txt")
            XCTAssertTrue(eventually { c.results.result?.query.raw == "txt" && c.results.result?.single?.options.kind == 3 })
            XCTAssertEqual(c.results.result?.single?.options.sort, .modified); XCTAssertEqual(c.results.result?.single?.options.pinyin, false)
            XCTAssertEqual(c.results.result?.single?.options.ascending, true)
            XCTAssertEqual(c.results.displayCount, 1)
            XCTAssertEqual(c.results.selectedItem?.name, "match.txt")
        }
    }
    func testUnavailableOrOfflineScopeDoesNotFallBackToAllFiles() throws {
        let (root, _, c) = try controller(); defer { try? FileManager.default.removeItem(at: root) }
        let before = c.session.token
        XCTAssertThrowsError(try c.activateFilter(filter(query: "txt", scope: root.appendingPathComponent("missing").path)))
        XCTAssertEqual(c.session.token, before); XCTAssertEqual(c.searchField.text, "txt")
        XCTAssertThrowsError(try c.activateFilter(filter(query: "txt", scope: "/private/unindexed")))
        XCTAssertEqual(c.session.token, before)
    }
    func testWebRouteCannotBeSavedButSavedFileQueryCannotBecomeWeb() throws {
        let (root, _, c) = try controller(); defer { try? FileManager.default.removeItem(at: root) }
        c.searchField.text = "g hello"
        XCTAssertThrowsError(try c.saveCurrentFilter(name: "Web"))
        let f = filter(query: "g hello")
        try c.activateFilter(f)
        guard case .files = c.queryRoute else { return XCTFail("Saved file filter became a web command") }
        XCTAssertEqual(c.searchField.text, "g hello")
        try c.saveCurrentFilter(name: "Literal File Filter")
        XCTAssertEqual(c.savedFilters.filters.first?.query, "g hello")
    }
    func testOfflineScopeIsRejectedWithoutChangingCurrentSession() throws {
        let (root, store, c) = try controller(); defer { try? FileManager.default.removeItem(at: root) }
        let offline = root.appendingPathExtension("offline")
        try FileManager.default.createDirectory(at: offline, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: offline) }
        try Data().write(to: offline.appendingPathComponent("offline.txt"))
        let config = IndexConfig(rootPath: offline.path, indexSystemDirs: true)
        let external = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        try c.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0,
            additionalSources: [SearchSource(id: "external", displayName: "Offline", isOnline: false, store: external)])
        let token = c.session.token
        XCTAssertThrowsError(try c.activateFilter(filter(query: "txt", scope: offline.path)))
        XCTAssertEqual(c.session.token, token); XCTAssertNil(c.session.directoryScope)
    }

}
