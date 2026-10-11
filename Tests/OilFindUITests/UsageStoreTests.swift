import AppKit
import Combine
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class UsageStoreTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryUsage-\(UUID().uuidString)")
        let file: URL
        let document: URL
        init() throws {
            file = root.appendingPathComponent("used.txt"); document = root.appendingPathComponent("usage.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: file)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func record(_ store: UsageStore, query: String = "used", activity: UsageRecord.Activity = .initiated, actionID: UUID = UUID(), epoch: UInt64? = nil) -> Bool {
            store.record(actionID: actionID, epoch: epoch ?? store.epoch, type: .file, url: file,
                         sourceID: "startup", activity: activity, query: query, context: "ordinary")
        }
        func scan() throws -> IndexStore {
            let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
            return IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        }
    }
    func testRestartAndRescanNeverPersistEntryID() throws {
        let f = try Fixture(), store = UsageStore(url: f.document, clock: { Date(timeIntervalSince1970: 1234) })
        XCTAssertTrue(f.record(store))
        let first = try f.scan()
        first.write { if let id = first.resolve(path: f.document.path) { first.remove(id) } }
        let replacement = first.compacted()
        let reloaded = UsageStore(url: f.document)
        XCTAssertEqual(reloaded.records.count, 1); XCTAssertEqual(reloaded.records[0].lastUsed.timeIntervalSince1970, 1234)
        let resolved = UsageStore.resolve(reloaded.records, system: reloaded.system,
            sources: [.init(id: "startup", displayName: "", isOnline: true, store: replacement)])
        XCTAssertEqual(resolved.first?.availability, .available)
        XCTAssertEqual(resolved.first?.url.path, f.file.path)
        XCTAssertNotNil(replacement.read { replacement.resolve(path: resolved[0].url.path) })
        let json = try String(contentsOf: f.document)
        XCTAssertFalse(json.contains("entryID")); XCTAssertFalse(json.contains("storeVersion"))
    }
    func testRealBookmarkMoveAndPathReuseFailClosed() throws {
        let f = try Fixture(), store = UsageStore(url: f.document)
        XCTAssertTrue(f.record(store)); let record = try XCTUnwrap(store.records.first)
        let moved = f.root.appendingPathComponent("renamed.txt")
        try FileManager.default.moveItem(at: f.file, to: moved)
        let movedOnly = store.system.resolve(try XCTUnwrap(record.identity))
        XCTAssertEqual(movedOnly.0.path, moved.path); XCTAssertEqual(movedOnly.1, .available)
        try Data("replacement".utf8).write(to: f.file)
        let reloaded = UsageStore(url: f.document)
        let resolved = reloaded.system.resolve(try XCTUnwrap(record.identity))
        if resolved.1 == .available { XCTAssertEqual(resolved.0.path, moved.path) }
        else { XCTAssertEqual(resolved.1, .missing) }
        var deterministic = HistorySystem(); deterministic.resolve = { _ in moved }
        XCTAssertEqual(deterministic.resolve(try XCTUnwrap(record.identity)).0.path, moved.path)
        XCTAssertEqual(deterministic.resolve(try XCTUnwrap(record.identity)).1, .available)
        XCTAssertFalse(try XCTUnwrap(record.identity).matches(f.file, system: reloaded.system))
        XCTAssertTrue(f.record(reloaded)); XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.records.first?.count, 1)
    }
    func testStaleBookmarkFallbackDeletionAndPermission() throws {
        let f = try Fixture()
        var system = HistorySystem()
        system.resolve = { _ in throw CocoaError(.fileReadCorruptFile) }
        let store = UsageStore(url: f.document, system: system)
        XCTAssertTrue(f.record(store)); let identity = try XCTUnwrap(store.records.first?.identity)
        XCTAssertEqual(system.resolve(identity).1, .available)
        system.readable = { _ in false }
        XCTAssertEqual(system.resolve(identity).1, .permission)
        var denied = system
        denied.identity = { _ in nil }; denied.unavailable = { _ in .permission }
        XCTAssertEqual(denied.resolve(identity).1, .permission)
        try FileManager.default.removeItem(at: f.file)
        XCTAssertEqual(system.resolve(identity).1, .missing)
    }
    func testSymlinkDestinationReplacementDoesNotInherit() throws {
        let f = try Fixture(), link = f.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.file)
        let system = HistorySystem(), identity = try XCTUnwrap(system.capture(link, sourceID: "startup"))
        try FileManager.default.moveItem(at: f.file, to: f.root.appendingPathComponent("saved"))
        try Data().write(to: f.file)
        XCTAssertEqual(system.resolve(identity).1, .missing)
    }
    func testClearDisableAndReenableRejectLateEpochs() throws {
        let f = try Fixture(), store = UsageStore(url: f.document)
        let beforeClear = store.epoch
        XCTAssertTrue(f.record(store)); try store.clear()
        XCTAssertFalse(f.record(store, epoch: beforeClear)); XCTAssertTrue(store.records.isEmpty)
        let beforeDisable = store.epoch
        try store.setEnabled(false)
        XCTAssertFalse(f.record(store)); try store.setEnabled(true)
        XCTAssertFalse(f.record(store, epoch: beforeDisable)); XCTAssertTrue(store.records.isEmpty)
        XCTAssertTrue(f.record(store)); XCTAssertEqual(UsageStore(url: f.document).records.count, 1)
    }
    func testDuplicateActionsCopiesAndQueryBounds() throws {
        let f = try Fixture(), store = UsageStore(url: f.document), action = UUID()
        XCTAssertTrue(f.record(store, actionID: action)); XCTAssertFalse(f.record(store, actionID: action))
        XCTAssertTrue(f.record(store, query: "private copied text", activity: .copied))
        XCTAssertEqual(store.records.count, 2)
        XCTAssertEqual(store.records[0].count, 1); XCTAssertEqual(store.records[0].launches, 0)
        XCTAssertEqual(store.records[0].activity, .copied); XCTAssertTrue(store.records[0].queries.isEmpty)
        XCTAssertEqual(store.records[1].queries, ["used"])
        for i in 0..<12 { XCTAssertTrue(f.record(store, query: "q\(i)")) }
        XCTAssertEqual(store.records[0].queries.count, 8)
        XCTAssertTrue(f.record(store, query: String(repeating: "s", count: 513)))
        XCTAssertEqual(store.records[0].queries.count, 8)
    }
    func testCopyDoesNotRefreshOpenRecencyOrContext() throws {
        let f = try Fixture(); var now = Date(timeIntervalSince1970: 100)
        let store = UsageStore(url: nil, clock: { now })
        XCTAssertTrue(f.record(store, query: "open query")); now = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(f.record(store, query: "copy query", activity: .copied))
        let launch = try XCTUnwrap(store.records.first { $0.activity == .initiated })
        XCTAssertEqual(launch.lastUsed.timeIntervalSince1970, 100)
        XCTAssertEqual(launch.count, 1); XCTAssertEqual(launch.queries, ["open query"])
        let copy = try XCTUnwrap(store.records.first { $0.activity == .copied })
        XCTAssertEqual(copy.launches, 0); XCTAssertTrue(copy.queries.isEmpty)
    }
    func testWebBodyAndURLNeverPersist() throws {
        let f = try Fixture(), store = UsageStore(url: f.document)
        XCTAssertTrue(store.record(actionID: UUID(), epoch: store.epoch, type: .web, url: nil, sourceID: "",
                                   keywordID: "wiki", activity: .initiated, query: "SECRET_QUERY", context: "web"))
        let json = try String(contentsOf: f.document)
        XCTAssertFalse(json.contains("SECRET_QUERY")); XCTAssertFalse(json.contains("https")); XCTAssertFalse(json.contains("bookmark"))
        XCTAssertEqual(UsageStore(url: f.document).records.first?.keywordID, "wiki")
    }
    func testCorruptAndUnknownVersionFailClosedUntilExplicitClear() throws {
        let f = try Fixture()
        for text in ["broken JSON", "{\"version\":9,\"enabled\":true,\"records\":[]}"] {
            try Data(text.utf8).write(to: f.document)
            let store = UsageStore(url: f.document)
            XCTAssertNotNil(store.error); XCTAssertTrue(store.records.isEmpty)
            XCTAssertFalse(f.record(store)); XCTAssertEqual(try String(contentsOf: f.document), text)
            try store.clear(); XCTAssertNil(store.error); XCTAssertTrue(f.record(store))
        }
    }
    func testFullFileHistoryPersistenceAndResolutionTimings() throws {
        let f = try Fixture(), seed = UsageStore(url: f.document)
        XCTAssertTrue(f.record(seed))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: f.document)) as? [String: Any])
        let record = try XCTUnwrap((document["records"] as? [[String: Any]])?.first)
        // Repeat a real bookmark payload to measure a full bounded document.
        document["records"] = (0..<1000).map { _ -> [String: Any] in
            var copy = record; copy["id"] = UUID().uuidString; return copy
        }
        try JSONSerialization.data(withJSONObject: document).write(to: f.document, options: .atomic)
        let store = UsageStore(url: f.document)
        XCTAssertEqual(store.records.count, 1000)
        var writes: [Double] = [], resolutions: [Double] = []
        for i in 0..<20 {
            let started = Date(); XCTAssertTrue(f.record(store, query: "q\(i)"))
            writes.append(Date().timeIntervalSince(started) * 1000)
        }
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: try f.scan())
        for _ in 0..<12 {
            let started = Date()
            XCTAssertEqual(UsageStore.resolve(store.records, system: store.system, sources: [source]).count, 200)
            resolutions.append(Date().timeIntervalSince(started) * 1000)
        }
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        print(String(format: "008 HISTORY 1000 records, %d bytes: atomic record p95=%.3fms, resolve 200 p95=%.3fms", try Data(contentsOf: f.document).count, p95(writes), p95(resolutions)))
    }
    func testRecordAndResolutionLimitsAtomicFileHasNoLeftovers() throws {
        let f = try Fixture(), store = UsageStore(url: f.document)
        for i in 0...UsageStore.recordLimit {
            XCTAssertTrue(store.record(actionID: UUID(), epoch: store.epoch, type: .web, url: nil, sourceID: "",
                                       keywordID: "k\(i)", activity: .initiated, query: "", context: "web"))
        }
        XCTAssertEqual(store.records.count, UsageStore.recordLimit)
        XCTAssertEqual(UsageStore(url: f.document).records.count, UsageStore.recordLimit)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: f.root.path)), ["used.txt", "usage.json"])
        var reads = 0, system = HistorySystem()
        system.identity = { _ in reads += 1; return FileIdentity.read(f.file) }
        let identity = try XCTUnwrap(HistorySystem().capture(f.file, sourceID: "startup"))
        let records = (0..<1000).map { _ in UsageRecord(id: UUID(), type: .file, identity: identity, keywordID: nil,
            activity: .initiated, count: 1, lastUsed: Date(), queries: [], context: "", launches: 1) }
        let source = SearchSource(id: "startup", displayName: "", isOnline: true, store: try f.scan())
        XCTAssertEqual(UsageStore.resolve(records, system: system, sources: [source]).count, 200)
        XCTAssertEqual(reads, 200)
        reads = 0
        XCTAssertEqual(UsageStore.resolve(records, system: system, sources: [.init(id: "startup", displayName: "", isOnline: false, store: source.store)]).first?.availability, .offline)
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(UsageStore.resolve(records, system: system, sources: [source], cancelled: { true }).isEmpty)
    }
    func testExecutorRecordsCapturedQueryAndFailurePolicies() throws {
        _ = NSApplication.shared
        let f = try Fixture(), usage = UsageStore(url: f.document), controller = SearchViewController(snapshot: true, usage: usage)
        try controller.prepareSnapshot(state: "results", query: "used", options: .init(), store: f.scan(), selection: 0)
        let executor = controller.actionExecutor
        executor.query = { "original query" }; executor.system.open = { _ in false }
        let rejected = try XCTUnwrap(controller.requestAction(.open))
        XCTAssertEqual(executor.execute(rejected), .failed(.systemRejected)); XCTAssertTrue(usage.records.isEmpty)
        executor.system.open = { _ in true }
        let request = try XCTUnwrap(controller.requestAction(.open))
        executor.query = { "later selection query" }
        XCTAssertEqual(executor.execute(request), .accepted)
        XCTAssertEqual(executor.execute(request), .cancelled(.alreadyDispatched))
        XCTAssertEqual(usage.records[0].count, 1); XCTAssertEqual(usage.records[0].queries, ["original query"])
        executor.system.copy = { _, _, _ in true }
        XCTAssertEqual(executor.execute(try XCTUnwrap(controller.requestAction(.copyPath))), .verified)
        XCTAssertEqual(usage.records[0].launches, 0); XCTAssertEqual(usage.records[0].activity, .copied)
        XCTAssertEqual(usage.records[1].launches, 1)
        let cancelled = try XCTUnwrap(controller.requestAction(.open))
        executor.cancel(cancelled, reason: .superseded)
        executor.execute(cancelled); XCTAssertEqual(usage.records.count, 2)
        XCTAssertEqual(usage.records.map(\.count), [1, 1])
    }
    func testDelayedApplicationCompletionAfterClearAndDisableCannotResurrect() throws {
        let f = try Fixture(), usage = UsageStore(url: f.document), session = SearchSession()
        let executor = ActionExecutor(session: session, sources: { [] }); executor.usage = usage
        executor.system.launcher.isApplication = { _ in true }
        var complete: ((Bool) -> Void)?
        executor.system.launch = { _, callback in complete = callback }
        let app = PaletteItem.application(.init(url: f.file, name: "Fixture", bundleIdentifier: nil, available: true))
        for clear in [true, false] {
            let request = try XCTUnwrap(executor.capture(.open, paletteItem: app))
            XCTAssertNil(executor.execute(request))
            if clear { try usage.clear() } else { try usage.setEnabled(false); try usage.setEnabled(true) }
            try XCTUnwrap(complete)(true); try XCTUnwrap(complete)(true)
            XCTAssertTrue(usage.records.isEmpty)
        }
        let request = try XCTUnwrap(executor.capture(.open, paletteItem: app)); executor.execute(request)
        session.end(); try XCTUnwrap(complete)(true)
        XCTAssertEqual(usage.records.count, 1)
    }
    private final class NavigationPermission: AccessibilityPermissionChecking {
        func isTrusted() -> Bool { true }
        func requestTrust() -> Bool { true }
    }
    private final class NavigationClient: DialogAccessibilityClient {
        var directory: URL
        let target: DialogTarget
        let fail: Bool
        init(directory: URL, target: DialogTarget, fail: Bool) { self.directory = directory; self.target = target; self.fail = fail }
        func capture(mode: DialogMode, generation: UUID, context: DialogCallContext) throws -> DialogTarget { target }
        func validate(_ target: DialogTarget, allowMistaryFocus: Bool, context: DialogCallContext) throws { try context.check() }
        func handoff(_ target: DialogTarget, context: DialogCallContext) throws { try context.check() }
        func preparePathControl(_ target: DialogTarget, context: DialogCallContext) throws { try context.check() }
        func observe(_ target: DialogTarget, context: DialogCallContext) throws -> DialogObservation {
            try context.check(); return .init(directory: directory, filename: "keep.txt", selectedFile: nil)
        }
        func writeDirectory(_ url: URL, target: DialogTarget, context: DialogCallContext) throws {
            try context.check(); if !fail { directory = url }
        }
        func confirmDirectory(_ target: DialogTarget, context: DialogCallContext) throws { try context.check() }
        func selectFile(_ url: URL, target: DialogTarget, context: DialogCallContext) throws { throw DialogFailure.selectionUnsupported }
    }
    func testAdapterCallbacksRecordQuickSwitchAndFileParentOnlyAtVerification() throws {
        _ = NSApplication.shared
        for quickSwitch in [false, true] {
            for fail in [false, true] {
                let f = try Fixture(), usage = UsageStore(url: nil), controller = SearchViewController(snapshot: true, usage: usage)
                let capability = DialogCapability(bundleIdentifier: "fixture", applicationVersion: "1", systemVersion: "fixture",
                    profileID: "test", mode: .open, selectsFiles: false)
                let target = DialogTarget(hostPID: 12, accessibilityPID: 12, windowIdentity: UUID(), panelIdentity: UUID(), mode: .open, generation: UUID())
                let context = DialogContext(mode: .open, target: target, capability: capability)
                let host = SearchContextTarget(processID: 12, bundleIdentifier: "fixture", windowIdentity: target.windowIdentity)
                controller.beginSession(source: .hotkey, context: SearchContext(mode: .open, target: host, directoryScope: nil, dialog: context))
                try controller.prepareSnapshot(state: "results", query: "used", options: .init(), store: f.scan(), selection: 0)
                let permission = NavigationPermission(), client = NavigationClient(directory: f.root.appendingPathComponent("other"), target: target, fail: fail)
                let navigator = DialogNavigation(client: client, permissions: permission)
                let adapter = DialogAdapter(permissions: permission, capabilities: [capability], enabled: { true })
                adapter.environmentMatches = { _, _ in true }; adapter.makeNavigator = { _ in navigator }
                controller.actionExecutor.dialog = adapter
                let done = expectation(description: "navigation result")
                adapter.onUpdate = {
                    if fail, case .failed = adapter.status { done.fulfill() }
                }
                let observation = usage.$records.dropFirst().sink { records in if !records.isEmpty { done.fulfill() } }
                controller.onActionEvent = { event in if event.outcome == .accepted { XCTAssertTrue(usage.records.isEmpty) } }
                if quickSwitch {
                    try controller.favorites.add(f.root)
                    controller.searchField.text = "new directory query"
                    controller.navigateDirectory(try XCTUnwrap(controller.directoryCandidates.first), token: controller.session.token)
                } else {
                    XCTAssertEqual(controller.actionExecutor.execute(try XCTUnwrap(controller.requestAction(.open))), .accepted)
                }
                wait(for: [done], timeout: 5)
                withExtendedLifetime(observation) {}
                if fail { XCTAssertTrue(usage.records.isEmpty) }
                else {
                    XCTAssertEqual(usage.records.count, 1); XCTAssertEqual(usage.records[0].count, 1)
                    XCTAssertEqual(usage.records[0].identity?.path, f.root.path)
                    XCTAssertEqual(usage.records[0].activity, .navigated)
                    XCTAssertEqual(usage.records[0].queries, [quickSwitch ? "new directory query" : "used"])
                }
                controller.endSession()
            }
        }
    }
    func testDirectoryCompletionAndManualCopyStaySeparateFromOpen() throws {
        _ = NSApplication.shared
        let f = try Fixture(), usage = UsageStore(url: nil), controller = SearchViewController(snapshot: true, usage: usage)
        try controller.prepareSnapshot(state: "results", query: "used", options: .init(), store: f.scan(), selection: 0)
        let executor = controller.actionExecutor
        controller.beginSession(source: .reopen, context: SearchContext(mode: .open, target: nil, directoryScope: nil))
        let request = try XCTUnwrap(controller.requestAction(.open))
        XCTAssertEqual(executor.execute(request), .failed(.dialogManual)); XCTAssertTrue(usage.records.isEmpty)
        executor.system.copy = { _, _, _ in true }
        controller.copyDialogPath()
        XCTAssertEqual(usage.records.first?.activity, .copied); XCTAssertEqual(usage.records.first?.launches, 0)
        let directory = executor.captureDirectoryUsage(f.root)
        executor.completeDirectoryUsage(directory, activity: .navigated)
        executor.completeDirectoryUsage(directory, activity: .navigated)
        XCTAssertEqual(usage.records[0].identity?.path, f.root.path)
        XCTAssertEqual(usage.records[0].activity, .navigated); XCTAssertEqual(usage.records[0].launches, 1)
        let stale = executor.captureDirectoryUsage(f.root); try usage.clear()
        executor.completeDirectoryUsage(stale, activity: .navigated)
        XCTAssertTrue(usage.records.isEmpty)
    }
    func testWebExecutorPersistsKeywordOnlyAfterAcceptance() throws {
        let f = try Fixture(), usage = UsageStore(url: f.document), executor = ActionExecutor(session: SearchSession(), sources: { [] })
        executor.usage = usage; executor.query = { "secret file query" }
        let keyword = WebKeyword.defaults[0], text = "CONFIDENTIAL_SEARCH"
        let item = PaletteItem.web(.init(keyword: keyword, text: text, url: try XCTUnwrap(keyword.searchURL(text))))
        executor.system.open = { _ in false }
        XCTAssertEqual(executor.execute(try XCTUnwrap(executor.capture(.open, paletteItem: item))), .failed(.systemRejected))
        XCTAssertTrue(usage.records.isEmpty)
        executor.system.open = { _ in true }
        XCTAssertEqual(executor.execute(try XCTUnwrap(executor.capture(.open, paletteItem: item))), .accepted)
        XCTAssertEqual(usage.records.first?.keywordID, keyword.id)
        let json = try String(contentsOf: f.document)
        XCTAssertFalse(json.contains(text)); XCTAssertFalse(json.contains("secret file query")); XCTAssertFalse(json.contains("google.com"))
    }
    func testCustomProcessOptInCountsLaunchOnly() throws {
        _ = NSApplication.shared
        let f = try Fixture(), usage = UsageStore(url: nil), controller = SearchViewController(snapshot: true, usage: usage)
        try controller.prepareSnapshot(state: "results", query: "used", options: .init(), store: f.scan(), selection: 0)
        let executor = controller.actionExecutor
        executor.system.executable = { _ in true }
        var callback: ((CommandEvent) -> Void)?
        executor.runCommand = { _, event in callback = event }
        for optIn in [false, true] {
            let definition = ActionDefinition(id: UUID(), name: "test", itemTypes: [.file], modes: ["ordinary"], permissions: [.processExecution],
                enabled: true, execution: .command(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], currentDirectory: nil), recordsUsage: optIn)
            XCTAssertTrue(definition.isValid)
            let file = try XCTUnwrap(controller.requestAction(.custom))
            executor.execute(try XCTUnwrap(executor.captureCustom(definition, file: file)))
            try XCTUnwrap(callback)(.started); try XCTUnwrap(callback)(.started)
            try XCTUnwrap(callback)(.cancelled(.commandFailed))
            XCTAssertEqual(usage.records.count, optIn ? 1 : 0)
        }
        XCTAssertEqual(usage.records[0].count, 1)
    }
}
