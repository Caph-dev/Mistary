import AppKit
import ApplicationServices
import XCTest
import OilFindCore
@testable import OilFindApp

final class FinderContextTests: XCTestCase {
    private final class Probe: FinderProbing {
        var observation: FinderObservation = .unavailable(.uncertain)
        var calls: [Int32] = []
        var validRecent = false
        func isStillValid(_ directory: FinderDirectory, processID: Int32) -> Bool { validRecent }
        func observe(processID: Int32, at date: Date) -> FinderObservation { calls.append(processID); return observation }
    }
    private func directory(_ path: String, id: UUID = UUID(), method: FinderDirectory.Method = .accessibility) -> FinderDirectory {
        FinderDirectory(windowIdentity: id, directoryURL: URL(fileURLWithPath: path), observedAt: Date(timeIntervalSince1970: 100), method: method)
    }
    func testSameWindowAndTabUpdateRequireNewObservation() {
        let probe = Probe(), context = FinderContext(probe: Probe())
        XCTAssertTrue(context.directories.isEmpty)
        let tested = FinderContext(probe: probe), id = UUID()
        let first = directory("/work", id: id), second = directory("/other", id: id)
        probe.observation = .directory(first); _ = tested.capture(processID: 1)
        XCTAssertEqual(tested.directories[id], first)
        probe.observation = .directory(second); _ = tested.capture(processID: 1)
        XCTAssertEqual(tested.directories[id], second); XCTAssertEqual(probe.calls.count, 2)
    }
    func testWindowReplacementAndProcessRestartInvalidateOldIdentity() {
        let probe = Probe(), context = FinderContext(probe: probe)
        let old = directory("/old"), new = directory("/new")
        probe.observation = .directory(old); _ = context.capture(processID: 1)
        probe.observation = .directory(new); _ = context.capture(processID: 1)
        XCTAssertNil(context.directories[old.windowIdentity]); XCTAssertEqual(context.directories.count, 1)
        probe.observation = .unavailable(.exited); _ = context.capture(processID: 2)
        XCTAssertTrue(context.directories.isEmpty)
    }
    func testUnavailableNeverReusesStaleOrAnotherWindow() {
        let probe = Probe(), context = FinderContext(probe: probe)
        for reason in [FinderUnavailable.recents, .search, .permission, .automation, .uncertain, .changed, .exited] {
            probe.observation = .directory(directory("/old")); _ = context.capture(processID: 1)
            probe.observation = .unavailable(reason)
            guard case .unavailable(let result) = context.capture(processID: 1) else { return XCTFail("Reused stale context") }
            XCTAssertEqual(result, reason); XCTAssertTrue(context.directories.isEmpty)
        }
    }
    func testRecentFinderCandidateRequiresLiveWindowValidation() {
        let probe = Probe(), context = FinderContext(probe: probe)
        let observed = directory("/observed")
        probe.observation = .directory(observed); _ = context.capture(processID: 1)
        probe.validRecent = true
        XCTAssertEqual(context.recentDirectory(), observed)
        probe.validRecent = false
        XCTAssertNil(context.recentDirectory()); XCTAssertTrue(context.directories.isEmpty)
        probe.validRecent = true
        XCTAssertNil(context.recentDirectory())
    }
    func testDesktopAndFrozenSessionDefaultToAllFiles() {
        let desktop = directory("/fixture/Desktop", method: .desktop), session = SearchSession()
        let context = SearchContext(mode: .finder, target: SearchContextTarget(processID: 1, bundleIdentifier: "com.apple.finder", windowIdentity: desktop.windowIdentity), directoryScope: desktop.directoryURL, finderDirectory: desktop)
        session.begin(source: .hotkey, context: context)
        XCTAssertNil(session.directoryScope)
        let token = session.token
        session.setDirectoryScope(desktop.directoryURL)
        XCTAssertFalse(session.isCurrent(token)); XCTAssertEqual(session.directoryScope, desktop.directoryURL)
        XCTAssertEqual(session.context.finderDirectory?.method, .desktop)
        session.begin(source: .menu, context: .ordinary)
        XCTAssertNil(session.directoryScope)
    }
    func testAXSearchInspectionFailsClosedOnReadErrors() {
        let window = AXUIElementCreateApplication(1)
        var system = FinderAXSystem()
        system.read = { _, key in
            switch key {
            case kAXRoleAttribute: return .value("AXWindow" as CFString)
            case kAXSubroleAttribute: return .absent
            default: return .failed
            }
        }
        XCTAssertEqual(SystemFinderProbe(ax: system).inspectSearch(window), .incomplete)
        system.read = { _, key in key == kAXRoleAttribute ? .value("AXWindow" as CFString) : .absent }
        XCTAssertEqual(SystemFinderProbe(ax: system).inspectSearch(window), .inactive)
        system.read = { _, key in
            if key == kAXRoleAttribute { return .value("AXSearchField" as CFString) }
            if key == kAXValueAttribute { return .value("query" as CFString) }
            return .absent
        }
        XCTAssertEqual(SystemFinderProbe(ax: system).inspectSearch(window), .active)
        system.read = { _, key in key == kAXRoleAttribute ? .value("AXSearchField" as CFString) : .failed }
        XCTAssertEqual(SystemFinderProbe(ax: system).inspectSearch(window), .incomplete)
    }
    func testAXSameWindowTabOrSearchChangesRejectCapturedDocument() {
        let window = AXUIElementCreateApplication(1), app = AXUIElementCreateApplication(2)
        var document = "file:///old", searching = false, childrenFail = false
        var system = FinderAXSystem()
        system.read = { element, key in
            if CFEqual(element, app), key == kAXFocusedWindowAttribute { return .value(window) }
            switch key {
            case kAXRoleAttribute: return .value((searching ? "AXSearchField" : "AXWindow") as CFString)
            case kAXDocumentAttribute: return .value(document as CFString)
            case kAXValueAttribute: return .value("query" as CFString)
            case kAXChildrenAttribute: return childrenFail ? .failed : .absent
            default: return .absent
            }
        }
        let probe = SystemFinderProbe(ax: system)
        XCTAssertTrue(probe.documentIsUnchanged(window, application: app, text: document))
        document = "file:///new"
        XCTAssertFalse(probe.documentIsUnchanged(window, application: app, text: "file:///old"))
        searching = true
        XCTAssertFalse(probe.documentIsUnchanged(window, application: app, text: document))
        searching = false; childrenFail = true
        XCTAssertFalse(probe.documentIsUnchanged(window, application: app, text: document))
    }
    func testAXWindowSwitchDuringSearchInspectionRejectsOldWindow() {
        let window = AXUIElementCreateApplication(1), app = AXUIElementCreateApplication(2), other = AXUIElementCreateApplication(3)
        var focused = window
        var system = FinderAXSystem()
        system.read = { element, key in
            if CFEqual(element, app), key == kAXFocusedWindowAttribute { return .value(focused) }
            if key == kAXRoleAttribute { return .value("AXWindow" as CFString) }
            if key == kAXDocumentAttribute { return .value("file:///old" as CFString) }
            if key == kAXChildrenAttribute { focused = other }
            return .absent
        }
        XCTAssertFalse(SystemFinderProbe(ax: system).documentIsUnchanged(window, application: app, text: "file:///old"))
    }
    func testSystemRecentDirectoryRejectsMissingChangedSearchingAndUnreadableWindow() {
        let window = AXUIElementCreateApplication(1), app = AXUIElementCreateApplication(2)
        var present = true, document = "file:///observed", searching = false, unreadable = false
        var system = FinderAXSystem()
        system.read = { element, key in
            if CFEqual(element, app), key == kAXWindowsAttribute { return .value((present ? [window] : []) as CFArray) }
            if unreadable { return .failed }
            if key == kAXRoleAttribute { return .value((searching ? "AXSearchField" : "AXWindow") as CFString) }
            if key == kAXDocumentAttribute { return .value(document as CFString) }
            if key == kAXValueAttribute { return .value("query" as CFString) }
            return .absent
        }
        let probe = SystemFinderProbe(ax: system), url = URL(fileURLWithPath: "/observed")
        XCTAssertTrue(probe.windowStillMatchesDirectory(window, application: app, url: url))
        present = false
        XCTAssertFalse(probe.windowStillMatchesDirectory(window, application: app, url: url))
        present = true; document = "file:///changed"
        XCTAssertFalse(probe.windowStillMatchesDirectory(window, application: app, url: url))
        document = "file:///observed"; searching = true
        XCTAssertFalse(probe.windowStillMatchesDirectory(window, application: app, url: url))
        searching = false; unreadable = true
        XCTAssertFalse(probe.windowStillMatchesDirectory(window, application: app, url: url))
    }
    func testStaticFinderScriptCompilesWithoutRunningAppleEvents() throws {
        let script = try XCTUnwrap(NSAppleScript(source: SystemFinderProbe.scriptSource))
        var error: NSDictionary?
        XCTAssertTrue(script.compileAndReturnError(&error), String(describing: error))
    }
    func testSupplementaryHitsCannotEscapeDirectoryScope() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryScopeSupplement-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inside"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("outside.txt"))
        try Data().write(to: root.appendingPathComponent("inside/inside.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        store.buildHash()
        let inside = try XCTUnwrap(store.resolve(path: root.appendingPathComponent("inside/inside.txt").path))
        let outside = try XCTUnwrap(store.resolve(path: root.appendingPathComponent("outside.txt").path))
        let options = SearchOptions(directoryScope: DirectoryScope(path: root.appendingPathComponent("inside").path))
        let result = try XCTUnwrap(Searcher.search(Query.parse("nomatch"), options: options, in: store))
        let supplemented = SearchPresentation(result).supplement([SupplementaryHit(sourceID: "startup", entryID: inside, detail: "inside"), SupplementaryHit(sourceID: "startup", entryID: outside, detail: "outside")], options: options)
        XCTAssertEqual(supplemented.count, 1); XCTAssertEqual(supplemented.row(0)?.id, inside)
    }
    func testScopeControlsInvalidateActionsAndPanelReuse() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryScopeUI-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("inside"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("outside.txt"))
        try Data().write(to: root.appendingPathComponent("inside/inside.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: true)
        _ = controller.view
        controller.additionalSources = { [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        let finder = directory(root.appendingPathComponent("inside").path)
        controller.beginSession(source: .hotkey, context: SearchContext(mode: .finder, target: nil, directoryScope: finder.directoryURL, finderDirectory: finder))
        try controller.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0)
        let request = try XCTUnwrap(controller.requestAction(.copyPath))
        controller.setDirectoryScope(finder.directoryURL)
        XCTAssertNotNil(controller.actionExecutor.validate(request))
        let done = expectation(description: "Scoped search submitted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            XCTAssertEqual(controller.results.result?.total, 1)
            XCTAssertEqual(controller.results.result?.directoryScope?.path, finder.directoryURL.path)
            controller.beginSession(source: .menu, context: .ordinary)
            controller.panelWillShow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                XCTAssertEqual(controller.results.result?.total, 2)
                XCTAssertNil(controller.results.result?.directoryScope)
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 3)
    }
}
