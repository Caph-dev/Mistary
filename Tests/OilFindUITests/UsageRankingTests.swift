import AppKit
import XCTest
import COilFind
@testable import OilFindCore
@testable import OilFindApp

final class UsageRankingTests: XCTestCase {
    private func synthetic(_ count: Int = 600, root: String = "/fixture") -> IndexStore {
        let names = [""] + (1...count).map { "match-\($0).txt" }
        let records = names.map { Array($0.utf8) }
        let store = IndexStore(rootPath: root, count: names.count, namesLen: records.reduce(0) { $0 + $1.count }, altCount: 0, altLen: 0,
            fingerprint: 0, homeIndex: .max, finishedAt: 0, caseSensitiveNames: true)
        var offset = 0
        for i in records.indices {
            store.nameOff[i] = UInt32(offset)
            for byte in records[i] { store.names[offset] = byte; offset += 1 }
            store.parent[i] = 0; store.flags[i] = i == 0 ? SiftFlag.dir : SiftFlag.userArea
            store.kind[i] = i == 0 ? 1 : 3; store.depth[i] = UInt8(i == 0 ? 1 : 2)
            store.sizeC[i] = UInt32(i); store.mtime[i] = UInt32(names.count - i)
        }
        store.nameOff[names.count] = UInt32(offset); store.altOff[0] = 0; store.buildHash()
        return store
    }
    private func history(_ path: String, source: String = "startup", query: String = "match", availability: DirectoryAvailability = .available,
                         date: Date = Date(), launches: Int = 5) -> ResolvedUsage {
        var info = stat(); info.st_ino = 42; info.st_dev = 1
        let node = FileIdentity.Node(info)
        let identity = HistoryIdentity(sourceID: source, path: path, bookmark: nil, volume: nil,
            file: FileIdentity(link: node, destination: node, resolvedPath: path))
        return ResolvedUsage(record: UsageRecord(id: UUID(), type: .file, identity: identity, keywordID: nil,
            activity: .initiated, count: launches, lastUsed: date, queries: [query], context: "ordinary", launches: launches),
            url: URL(fileURLWithPath: path), availability: availability)
    }
    private func present(_ store: IndexStore, text: String = "match", options: SearchOptions = .init()) throws -> SearchPresentation {
        SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse(text), options: options, in: store)))
    }
    private func keys(_ presentation: SearchPresentation) -> [SearchPresentation.RowKey] {
        (0..<presentation.count).compactMap { index in
            presentation.row(index).map { .init(sourceID: $0.source.id, id: $0.id) }
        }
    }
    private func verifyRoundTrip(_ presentation: SearchPresentation, file: StaticString = #filePath, line: UInt = #line) {
        let rows = keys(presentation)
        XCTAssertEqual(rows.count, Set(rows).count, file: file, line: line)
        for i in 0..<presentation.count {
            guard let row = presentation.row(i) else { XCTFail("Missing row", file: file, line: line); continue }
            let path = row.source.store.read { row.source.store.path(row.id) }
            XCTAssertEqual(presentation.index(sourceID: row.source.id, store: row.source.store, id: row.id, path: path), i, file: file, line: line)
        }
    }
    func testPrefixOutsidePromotionPreservesCompleteTraversalAndCounts() throws {
        let store = synthetic(), presentation = try present(store), core = try XCTUnwrap(presentation.single)
        let outside = try XCTUnwrap(core.items.last), path = store.path(outside)
        XCTAssertFalse(core.items.prefix(200).contains(outside))
        UsageRanker.rank(presentation, history: [history(path)], options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.row(0)?.id, outside)
        XCTAssertEqual(presentation.rankingMode, .personalBounded); XCTAssertEqual(presentation.personalPrefixCount, 201)
        XCTAssertEqual(presentation.total, core.total); XCTAssertEqual(presentation.count, core.total)
        XCTAssertEqual(presentation.sortedCount, core.sortedCount)
        XCTAssertEqual(Set(keys(presentation).map(\.id)), Set(core.items)); verifyRoundTrip(presentation)
        let prefixIDs = Set((0..<presentation.personalPrefixCount).compactMap { presentation.row($0)?.id })
        let suffix = (presentation.personalPrefixCount..<presentation.count).compactMap { presentation.row($0)?.id }
        XCTAssertEqual(suffix, core.items.filter { !prefixIDs.contains($0) })
    }
    func testLargePartiallySortedCoreDoesNotLoseOrDuplicateMatches() throws {
        let store = synthetic(200_100), presentation = try present(store), core = try XCTUnwrap(presentation.single)
        XCTAssertEqual(core.sortedCount, 5000)
        let outside = try XCTUnwrap(core.items.last)
        UsageRanker.rank(presentation, history: [history(store.path(outside))], options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.row(0)?.id, outside)
        let rows = keys(presentation)
        XCTAssertEqual(rows.count, core.total); XCTAssertEqual(Set(rows).count, core.total)
        XCTAssertEqual(Set(rows.map(\.id)), Set(core.items)); XCTAssertEqual(core.sortedCount, 5000)
        for position in [0, 200, 201, 4999, 5000, presentation.count - 1] {
            let row = try XCTUnwrap(presentation.row(position))
            XCTAssertEqual(presentation.index(sourceID: row.source.id, store: store, id: row.id, path: store.path(row.id)), position)
        }
    }
    func testExplicitSortsBypassPersonalizationIncludingEmptyAndSupplementary() throws {
        let store = synthetic()
        for sort in [SortKey.name, .size, .modified] {
            for text in ["", "match"] {
                let options = SearchOptions(sort: sort, ascending: true)
                let presentation = try present(store, text: text, options: options), original = keys(presentation)
                XCTAssertEqual(UsageRanker.rank(presentation, history: [history("/fixture/match-600.txt")], options: options, context: "ordinary"), 0)
                XCTAssertEqual(keys(presentation), original); XCTAssertEqual(presentation.rankingMode, .original)
            }
        }
    }
    func testEmptyQueryIncludesUsageOutsideModified200WithGroupsAndNoDuplicates() throws {
        let store = synthetic(), presentation = try present(store, text: "")
        XCTAssertEqual(presentation.count, 200)
        let now = Date()
        let used = [history("/fixture/match-600.txt", query: "", date: now.addingTimeInterval(-60)),
                    history("/fixture/match-1.txt", query: "", date: now)]
        UsageRanker.rank(presentation, history: used, options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.count, 201); XCTAssertEqual(presentation.total, 200)
        XCTAssertEqual(presentation.row(0)?.id, 1); XCTAssertEqual(presentation.row(1)?.id, 600)
        XCTAssertEqual(presentation.usageGroup(at: 0), "usage.recent"); XCTAssertEqual(presentation.usageGroup(at: 1), "usage.recent")
        XCTAssertEqual(presentation.usageGroup(at: 2), "usage.modified"); verifyRoundTrip(presentation)
        // A used source root is a valid directory row even though its index name is empty.
        let rootRecent = try present(store, text: "")
        UsageRanker.rank(rootRecent, history: [history("/fixture", query: "")], options: .init(), context: "ordinary")
        _ = NSApplication.shared
        let controller = SearchViewController(snapshot: true)
        controller.present(rootRecent)
        XCTAssertEqual(controller.results.selectedItem?.name, "fixture")
        XCTAssertEqual(controller.results.selectedItem?.path, "/fixture")
        XCTAssertEqual(try XCTUnwrap(controller.requestAction(.copyPath)).target.url.path, "/fixture")
    }
    func testCopiesAndUnavailableOrUnindexedHistoryNeverPromote() throws {
        let store = synthetic(), presentation = try present(store)
        let values = [history("/fixture/match-600.txt", availability: .offline), history("/fixture/match-599.txt", availability: .missing),
            history("/fixture/match-598.txt", availability: .permission), history("/fixture/match-597.txt", launches: 0), history("/outside/match.txt")]
        UsageRanker.rank(presentation, history: values, options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.rankingMode, .original)
        XCTAssertEqual(keys(presentation).map(\.id), presentation.single?.items)
    }
    func testFullORNOTRegexPathExtensionDateKindAndScopeSemantics() throws {
        let store = synthetic()
        let cases: [(String, SearchOptions, Bool)] = [
            ("absent | match !forbidden", .init(), true), ("absent | match !match-600", .init(), false),
            ("regex:^match-600\\.txt$ ext:txt", .init(), true), ("match ext:pdf", .init(), false),
            ("match path:/fixture/match-600", .init(), true), ("match path:/fixture/match-599", .init(), false),
            ("match size:>500", .init(), true), ("match size:<500", .init(), false),
            ("match dm:1970-01-01", .init(), true), ("match dm:>2025-01-01", .init(), false),
            ("file:match-600", .init(), true), ("folder:match-600", .init(), false),
            ("match", .init(kind: 3), true), ("match", .init(kind: 4), false),
            ("match", .init(directoryScope: .init(path: "/fixture")), true),
            ("match", .init(directoryScope: .init(path: "/fixture/missing")), false)
        ]
        for (query, options, eligible) in cases {
            let result = try present(store, text: query, options: options)
            UsageRanker.rank(result, history: [history("/fixture/match-600.txt", query: query)], options: options, context: "ordinary")
            XCTAssertEqual(result.rankingMode == .personalBounded, eligible, query)
            XCTAssertEqual(Set(keys(result).map(\.id)), Set(result.single!.items), query)
            if eligible { XCTAssertEqual(result.row(0)?.id, 600, query) }
        }
    }
    func testExactNameBeatsRepeatedSameQueryUsage() throws {
        let store = synthetic()
        let attrs = EntryAttrs(type: 0, size: 1)
        let long = store.write { Array("prefix-match-1.txt".utf8).withUnsafeBufferPointer { store.insert(parent: 0, name: $0, attrs: attrs) } }
        for query in ["match-1.txt", "match-1.txt ext:txt", "absent | file:match-1.txt"] {
            let updated = try present(store, text: query)
            UsageRanker.rank(updated, history: [history(store.path(long), query: query, launches: 999_999)], options: .init(), context: "ordinary")
            XCTAssertEqual(updated.row(0)?.id, 1, query)
        }
    }
    func testMultipleSourcesSupplementAndSelectionRoundTrip() throws {
        _ = NSApplication.shared
        let a = synthetic(350, root: "/a"), b = synthetic(350, root: "/b")
        let sources = [SearchSource(id: "a", displayName: "A", isOnline: true, store: a), SearchSource(id: "b", displayName: "B", isOnline: true, store: b)]
        let options = SearchOptions(), query = Query.parse("match")
        let presentation = SearchPresentation(try XCTUnwrap(MultiSearcher.search(query, options: options, in: sources)))
        let values = [history("/b/match-350.txt", source: "b")]
        UsageRanker.rank(presentation, history: values, options: options, context: "ordinary")
        XCTAssertEqual(presentation.row(0)?.source.id, "b"); XCTAssertEqual(presentation.row(0)?.id, 350)
        verifyRoundTrip(presentation)
        let combined = presentation.supplement([SupplementaryHit(sourceID: "a", entryID: 1, detail: "Supplement")], options: options)
        UsageRanker.rank(combined, history: values, options: options, context: "ordinary")
        XCTAssertEqual(combined.total, 700); verifyRoundTrip(combined)
        let controller = SearchViewController(snapshot: true)
        controller.present(presentation); controller.results.select(0)
        let selected = try XCTUnwrap(controller.results.selectedItem)
        controller.results.refresh(combined)
        XCTAssertEqual(controller.results.selectedItem?.path, selected.path)
        let request = try XCTUnwrap(controller.requestAction(.open))
        XCTAssertEqual(request.target.sourceID, "b"); XCTAssertEqual(request.target.entryID, 350)
    }
    func testCopyAndWebRecordsDoNotConsumeRankingCandidateWindowOrRefreshUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryCopyRanking-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("match-a.txt"), b = root.appendingPathComponent("match-b.txt")
        try Data().write(to: a); try Data().write(to: b)
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        var now = Date(timeIntervalSince1970: 100)
        let usage = UsageStore(url: nil, clock: { now })
        for file in [a, b] {
            XCTAssertTrue(usage.record(actionID: UUID(), epoch: usage.epoch, type: .file, url: file, sourceID: "startup",
                                       activity: .initiated, query: "match", context: "ordinary"))
            now.addTimeInterval(100)
        }
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: store)
        let original = try present(store, text: "")
        UsageRanker.rank(original, history: UsageStore.resolve(usage.records, system: usage.system, sources: [source]), options: .init(), context: "ordinary")
        XCTAssertEqual(original.row(0)?.id, store.resolve(path: b.path))
        XCTAssertTrue(usage.record(actionID: UUID(), epoch: usage.epoch, type: .file, url: a, sourceID: "startup",
                                   activity: .copied, query: "", context: "ordinary"))
        let copy = try XCTUnwrap(usage.records.first { $0.activity == .copied })
        let web = UsageRecord(id: UUID(), type: .web, identity: nil, keywordID: "g", activity: .initiated,
            count: 1, lastUsed: now, queries: [], context: "web", launches: 1)
        let noisyCopies = Array(repeating: copy, count: 250) + Array(repeating: web, count: 250) + usage.records
        let resolved = UsageStore.resolve(noisyCopies, system: usage.system, sources: [source])
        XCTAssertEqual(resolved.count, 2); XCTAssertTrue(resolved.allSatisfy { $0.record.activity != .copied })
        let after = try present(store, text: "")
        UsageRanker.rank(after, history: resolved, options: .init(), context: "ordinary")
        XCTAssertEqual(keys(after), keys(original))
    }
    func testSupplementaryOnlyHitsStayOutsidePersonalCandidatePrefix() throws {
        let store = synthetic(3), result = try present(store, text: "match-1")
        let combined = result.supplement([SupplementaryHit(sourceID: "startup", entryID: 2, detail: "Other channel")], options: .init())
        UsageRanker.rank(combined, history: [history("/fixture/match-1.txt", query: "match-1"), history("/fixture/match-2.txt", query: "match-1")], options: .init(), context: "ordinary")
        XCTAssertEqual(combined.personalPrefixCount, 1)
        XCTAssertEqual(combined.single?.total, 1); XCTAssertEqual(combined.single?.sortedCount, 1)
        XCTAssertEqual(combined.row(0)?.id, 1); XCTAssertEqual(combined.row(1)?.id, 2)
        verifyRoundTrip(combined)
    }
    func testEmptySupplementAndUsageOutsideRecentPrefixDeduplicate() throws {
        let store = synthetic(), presentation = try present(store, text: "")
        let values = [history("/fixture/match-600.txt", query: "")]
        UsageRanker.rank(presentation, history: values, options: .init(), context: "ordinary")
        let combined = presentation.supplement([SupplementaryHit(sourceID: "startup", entryID: 600, detail: "Extra")], options: .init())
        UsageRanker.rank(combined, history: values, options: .init(), context: "ordinary")
        XCTAssertEqual(combined.count, 201); XCTAssertEqual(combined.row(0)?.id, 600)
        XCTAssertEqual(combined.personalPrefixCount, 1); verifyRoundTrip(combined)
    }
    func testOfflineSourceAndCancelledRankingDoNotPromote() throws {
        let store = synthetic(), sources = [SearchSource(id: "disk", displayName: "Disk", isOnline: false, store: store)]
        let result = SearchPresentation(try XCTUnwrap(MultiSearcher.search(Query.parse("match"), in: sources)))
        UsageRanker.rank(result, history: [history("/fixture/match-600.txt", source: "disk")], options: .init(), context: "ordinary")
        XCTAssertEqual(result.rankingMode, .original)
        let online = try present(store)
        UsageRanker.rank(online, history: [history("/fixture/match-600.txt")], options: .init(), context: "ordinary", cancelled: { true })
        XCTAssertEqual(online.rankingMode, .original)
    }
    func testPinyinAndAncestorNegationStayEquivalentToCore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryPinyin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("blocked"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("blocked/中文.txt")
        try Data().write(to: file)
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        for (text, pinyin, expected) in [("zhongwen", true, true), ("zhongwen", false, false), ("中文 !blocked", true, false), ("absent | 中文 !other", true, true)] {
            let options = SearchOptions(pinyin: pinyin), result = try present(store, text: text, options: options)
            UsageRanker.rank(result, history: [history(file.path, query: text)], options: options, context: "ordinary")
            XCTAssertEqual(result.rankingMode == .personalBounded, expected, text)
            XCTAssertEqual(Set(keys(result).map(\.id)), Set(result.single!.items))
        }
    }
    func testHistoryPromotionWaitsForHashWithoutScanningPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryUsageHash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("used.txt"); try Data().write(to: file)
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let presentation = try present(store, text: "used")
        UsageRanker.rank(presentation, history: [history(file.path)], options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.rankingMode, .original)
        store.write { store.buildHash() }
        UsageRanker.rank(presentation, history: [history(file.path)], options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.rankingMode, .personalBounded); XCTAssertEqual(presentation.count, 1)
    }
    func testPartialMatchSnapshotDisablesPromotion() throws {
        let store = synthetic(), full = try XCTUnwrap(try present(store).single)
        let partial = SearchResult(store: store, query: full.query, options: full.options,
            items: Array(full.items.prefix(200)), total: full.total, sortedCount: 200, elapsedMs: 0, scores: Array(full.scores.prefix(200)))
        let presentation = SearchPresentation(partial)
        UsageRanker.rank(presentation, history: [history("/fixture/match-600.txt")], options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.rankingMode, .original); XCTAssertEqual(presentation.count, 200)
    }
    private func waitForSearch(_ queue: DispatchQueue) {
        let done = expectation(description: "Search and queued usage refresh committed")
        DispatchQueue.main.async {
            queue.async { DispatchQueue.main.async { done.fulfill() } }
        }
        wait(for: [done], timeout: 5)
    }
    func testClearRejectsInflightHistoryAndOlderQueryAndPreservesNewSelection() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryUsageRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let usage = UsageStore(url: nil), queue = DispatchQueue(label: "Mistary.usage.race")
        XCTAssertTrue(usage.record(actionID: UUID(), epoch: usage.epoch, type: .file, url: root.appendingPathComponent("b.txt"), sourceID: "startup",
                                   activity: .initiated, query: "txt", context: "ordinary"))
        let controller = SearchViewController(snapshot: true, usage: usage, searchQueue: queue)
        try controller.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0)
        queue.suspend(); controller.startSearch()
        try usage.clear()
        controller.searchField.text = "a.txt"; controller.startSearch()
        queue.resume(); waitForSearch(queue)
        XCTAssertEqual(controller.results.result?.query.raw, "a.txt")
        XCTAssertEqual(controller.results.result?.rankingMode, .original)
        XCTAssertEqual(controller.results.result?.usageRevision, usage.revision)
        XCTAssertEqual(controller.results.selectedItem?.path, root.appendingPathComponent("a.txt").path)
    }
    func testReopeningCachedPanelAfterUsageAndDisableReranksAndKeepsSelection() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryUsageCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["a.txt", "b.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        let usage = UsageStore(url: nil), queue = DispatchQueue(label: "Mistary.usage.cache")
        let controller = SearchViewController(snapshot: false, favorites: FavoritesStore(url: nil), launcher: LauncherPreferences(url: nil),
            customActions: ActionDefinitions(url: nil), savedFilters: SavedFiltersStore(url: nil), usage: usage, searchQueue: queue)
        controller.additionalSources = { [.init(id: "startup", displayName: "", isOnline: true, store: store)] }
        try controller.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0)
        controller.startSearch(); waitForSearch(queue)
        let generation = controller.session.queryGeneration
        controller.panelWillShow(); XCTAssertEqual(controller.session.queryGeneration, generation)
        let selected = controller.results.selectedItem?.path
        XCTAssertTrue(usage.record(actionID: UUID(), epoch: usage.epoch, type: .file, url: root.appendingPathComponent("b.txt"), sourceID: "startup",
                                   activity: .initiated, query: "txt", context: "ordinary"))
        controller.panelWillShow(); waitForSearch(queue)
        XCTAssertEqual(controller.results.result?.row(0)?.id, store.resolve(path: root.appendingPathComponent("b.txt").path))
        XCTAssertEqual(controller.results.selectedItem?.path, selected)
        XCTAssertEqual(controller.results.result?.rankingMode, .personalBounded)
        XCTAssertTrue(controller.footer.text.contains(L10n.text("usage.footer", "2", "2")))
        try usage.setEnabled(false); waitForSearch(queue)
        XCTAssertEqual(controller.results.result?.rankingMode, .original)
        XCTAssertEqual(controller.results.selectedItem?.path, selected)
        XCTAssertEqual(controller.results.result?.usageRevision, usage.revision)
    }
    func testEmptyApplicationHistoryDeduplicatesIndexedAppsAndHonorsForceFilesAndKind() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryAppHistory-\(UUID().uuidString)")
        let indexedRoot = root.appendingPathComponent("indexed"), indexed = indexedRoot.appendingPathComponent("Indexed.app"), unindexed = root.appendingPathComponent("Other.app")
        try FileManager.default.createDirectory(at: indexed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unindexed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = IndexConfig(rootPath: indexedRoot.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.write { store.buildHash() }
        store.write { for i in 1..<store.count { store.flags[i] |= SiftFlag.userArea } }
        let usage = UsageStore(url: nil), queue = DispatchQueue(label: "Mistary.app.history")
        for app in [indexed, unindexed] {
            XCTAssertTrue(usage.record(actionID: UUID(), epoch: usage.epoch, type: .application, url: app, sourceID: "startup",
                                       activity: .initiated, query: "", context: "application"))
        }
        let controller = SearchViewController(snapshot: true, usage: usage, searchQueue: queue)
        try controller.prepareSnapshot(state: "recent", query: "", options: .init(), store: store, selection: 0)
        controller.startSearch(); waitForSearch(queue)
        let presentation = try XCTUnwrap(controller.results.result)
        XCTAssertEqual(presentation.launcherItems.count, 1)
        if case .application(let app) = presentation.launcherItems[0] { XCTAssertEqual(app.url.path, unindexed.path); XCTAssertEqual(app.usageGroup, "usage.recent") }
        else { XCTFail("Expected application history") }
        XCTAssertEqual(presentation.displayCount, 2); XCTAssertEqual(presentation.total, 1)
        controller.forceFileSearch(); waitForSearch(queue)
        XCTAssertTrue(controller.results.result?.launcherItems.isEmpty == true)
        controller.filters.options = .init(kind: 4); controller.startSearch(); waitForSearch(queue)
        XCTAssertEqual(controller.results.displayCount, 0)
    }
    func testSyntheticSearchAndRankingTimings() throws {
        let store = synthetic(200_100), query = Query.parse("match"), values = [history("/fixture/match-200100.txt")]
        var base: [Double] = [], ranked: [Double] = [], rankOnly: [Double] = []
        for i in 0..<24 {
            let started = Date()
            let result = try XCTUnwrap(Searcher.search(query, in: store))
            let baseline = Date().timeIntervalSince(started) * 1000
            let presentation = SearchPresentation(result), rankingStart = Date()
            UsageRanker.rank(presentation, history: values, options: .init(), context: "ordinary")
            let extra = Date().timeIntervalSince(rankingStart) * 1000
            XCTAssertEqual(presentation.count, result.total)
            if i > 3 { base.append(baseline); ranked.append(baseline + extra); rankOnly.append(extra) }
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        print(String(format: "008 SYNTHETIC 200100 matches: search p95=%.3fms, search+rank p95=%.3fms, rank p95=%.3fms", p95(base), p95(ranked), p95(rankOnly)))
    }
    func testFavoriteCandidateUsesSameMembershipAndExplicitSortRules() throws {
        let store = synthetic(), presentation = try present(store)
        UsageRanker.rank(presentation, history: [], favorites: [URL(fileURLWithPath: "/fixture/match-600.txt"), URL(fileURLWithPath: "/outside/match.txt")], options: .init(), context: "ordinary")
        XCTAssertEqual(presentation.row(0)?.id, 600); verifyRoundTrip(presentation)
        let excluded = try present(store, text: "match !match-600")
        UsageRanker.rank(excluded, history: [], favorites: [URL(fileURLWithPath: "/fixture/match-600.txt")], options: .init(), context: "ordinary")
        XCTAssertEqual(excluded.rankingMode, .original)
    }
}
