import AppKit
import XCTest
import OilFindCore
@testable import OilFindApp

final class PaletteResultsTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: IndexStore
        let launcher: LauncherPreferences
        let controller: SearchViewController
        let queryQueue = DispatchQueue(label: "fixture.palette.search")
        var opened: [URL] = []
        var launched: [URL] = []
        var completion: ((Bool) -> Void)?
        var events: [PaletteActionEvent] = []
        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("Palette-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["alpha.txt", "beta.txt", "g hello.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Editor.app"), withIntermediateDirectories: true)
            let config = IndexConfig(rootPath: root.path)
            let fixtureStore = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
            fixtureStore.write { fixtureStore.buildHash() }
            store = fixtureStore
            var system = LauncherSystem()
            system.isApplication = { FileManager.default.fileExists(atPath: $0.path) && $0.pathExtension == "app" }
            system.bundleIdentifier = { _ in "fixture.editor" }
            launcher = LauncherPreferences(url: nil, system: system)
            controller = SearchViewController(snapshot: true, launcher: launcher, searchQueue: queryQueue)
            try controller.prepareSnapshot(state: "results", query: "txt", options: .init(sort: .name), store: store, selection: 0)
            controller.actionExecutor.system.launcher = system
            controller.actionExecutor.system.open = { [weak self] url in self?.opened.append(url); return true }
            controller.actionExecutor.system.launch = { [weak self] url, callback in self?.launched.append(url); self?.completion = callback }
            controller.onPaletteActionEvent = { [weak self] in self?.events.append($0) }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var app: ApplicationPaletteItem {
            ApplicationPaletteItem(url: root.appendingPathComponent("Editor.app"), name: "编辑器", bundleIdentifier: "fixture.editor", available: true)
        }
        func request(_ action: FileAction = .open, item: PaletteItem? = nil) throws -> PaletteActionRequest {
            try XCTUnwrap(controller.actionExecutor.capture(action, paletteItem: item ?? .application(app)))
        }
        func waitForFileResult(_ predicate: (SearchPresentation) -> Bool = { _ in true }) throws {
            let until = Date().addingTimeInterval(2)
            while Date() < until {
                if let result = controller.results.result, predicate(result) { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            XCTFail("File query was not submitted")
        }
    }
    func testAliasDedupUsesPathAndRetainsOtherInstallationWithSameBundle() throws {
        let f = try Fixture()
        try f.launcher.add(f.app.url, alias: "editor")
        let second = f.root.appendingPathComponent("Other/Editor.app")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try f.launcher.add(second, alias: "editor")
        let result = SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse("Editor"), in: f.store)))
        result.addAliases(f.launcher.candidates(for: "editor"))
        XCTAssertEqual(result.launcherItems.count, 1)
        guard case .application(let retained) = result.launcherItems[0] else { return XCTFail() }
        XCTAssertEqual(retained.url, second)
        XCTAssertEqual(retained.bundleIdentifier, f.app.bundleIdentifier)
        XCTAssertEqual(result.count, 1)
    }
    func testFileSelectionAndSnapshotSurviveAliasInsertionRemovalAndSupplementMerge() throws {
        let f = try Fixture()
        let before = try XCTUnwrap(f.controller.results.result)
        f.controller.results.select(1)
        let original = try XCTUnwrap(f.controller.results.selectedItem)
        let captured = try XCTUnwrap(f.controller.requestAction(.copyName))
        var copied: [String] = []
        f.controller.actionExecutor.system.copy = { _, _, name in copied.append(name); return true }
        let after = SearchPresentation(try XCTUnwrap(Searcher.search(Query.parse("txt"), options: .init(sort: .name), in: f.store)))
        after.launcherItems = [.application(f.app)]
        f.controller.results.refresh(after)
        XCTAssertEqual(f.controller.results.selectedRow, 2)
        XCTAssertEqual(f.controller.results.selectedItem?.path, original.path)
        XCTAssertEqual(f.controller.actionExecutor.execute(captured), .verified)
        XCTAssertEqual(copied, [original.name])
        let combined = after.supplement([], options: .init())
        XCTAssertEqual(combined.launcherItems.map(\.identity), after.launcherItems.map(\.identity))
        f.controller.results.refresh(before)
        XCTAssertEqual(f.controller.results.selectedRow, 1)
        XCTAssertEqual(f.controller.results.selectedItem?.path, original.path)
    }
    func testApplicationSelectionIdentitySurvivesReordering() throws {
        let f = try Fixture()
        let second = ApplicationPaletteItem(url: f.root.appendingPathComponent("Other.app"), name: "other", bundleIdentifier: nil, available: false)
        f.controller.results.showCommands([.application(f.app), .application(second)])
        f.controller.results.select(1)
        let identity = f.controller.results.selectedPaletteItem?.identity
        f.controller.results.showCommands([.application(second), .application(f.app)], preserveSelection: true)
        XCTAssertEqual(f.controller.results.selectedRow, 0)
        XCTAssertEqual(f.controller.results.selectedPaletteItem?.identity, identity)
    }
    func testWebRowHasNoFileTargetMetadataDragOrFileActions() throws {
        let f = try Fixture()
        f.controller.searchField.text = "g 中文 & # %"; f.controller.startSearch()
        XCTAssertEqual(f.controller.results.displayCount, 1)
        XCTAssertNil(f.controller.results.result)
        XCTAssertNil(f.controller.results.selectedItem)
        XCTAssertNil(f.controller.results.selectedID)
        XCTAssertNil(f.controller.results.onPasteboardWriter?(0))
        for action in [FileAction.reveal, .preview, .copyFile, .copyPath, .copyName, .trash, .contextNavigation] {
            XCTAssertNil(f.controller.requestAction(action))
            f.controller.performAction(action)
        }
        XCTAssertTrue(f.opened.isEmpty); XCTAssertTrue(f.launched.isEmpty)
        let menu = f.controller.contextMenu()
        XCTAssertEqual(menu.items.count, 1)
        let request = try XCTUnwrap(menu.items[0].representedObject as? PaletteActionRequest)
        guard case .web(let web) = request.item else { return XCTFail() }
        f.controller.paletteContextAction(menu.items[0])
        XCTAssertEqual(f.opened, [web.url])
        XCTAssertEqual(f.events.map(\.outcome), [.accepted])
    }
    func testCommandSwitchInvalidatesQueuedFileResultsAndCapturedActions() throws {
        let f = try Fixture()
        let request = try XCTUnwrap(f.controller.requestAction(.open))
        let gate = DispatchSemaphore(value: 0)
        f.queryQueue.async { gate.wait() }
        f.controller.searchField.text = "alpha"; f.controller.startSearch()
        f.controller.searchField.text = "wiki 中文"; f.controller.startSearch()
        let drained = expectation(description: "Old file work drained after command switch")
        f.queryQueue.async { DispatchQueue.main.async { drained.fulfill() } }
        gate.signal(); wait(for: [drained], timeout: 2)
        XCTAssertNil(f.controller.results.result)
        guard case .web = f.controller.results.selectedPaletteItem else { return XCTFail() }
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(.staleSession))
        XCTAssertTrue(f.opened.isEmpty)
    }
    func testComputedFileResultAwaitingMainThreadPublicationCannotOverwriteCommand() throws {
        let f = try Fixture()
        f.controller.searchField.text = "alpha"; f.controller.startSearch()
        // Keep the main thread occupied until computation has queued its publication.
        let computed = DispatchSemaphore(value: 0)
        f.queryQueue.async { computed.signal() }
        XCTAssertEqual(computed.wait(timeout: .now() + 2), .success)
        f.controller.searchField.text = "g hello"; f.controller.startSearch()
        let published = expectation(description: "Main-thread publication drained")
        DispatchQueue.main.async { published.fulfill() }
        wait(for: [published], timeout: 2)
        XCTAssertNil(f.controller.results.result)
        guard case .web = f.controller.results.selectedPaletteItem else { return XCTFail() }
    }
    func testRemovingLastAliasClearsCachedRowsOnReopen() throws {
        let f = try Fixture()
        f.controller.additionalSources = { [store = f.store] in [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        try f.launcher.add(f.app.url, alias: "alias")
        f.controller.searchField.text = "alias"; f.controller.startSearch()
        try f.waitForFileResult { $0.query.raw == "alias" && $0.launcherItems.count == 1 }
        let before = try XCTUnwrap(f.controller.results.result)
        try f.launcher.remove(try XCTUnwrap(f.launcher.aliases.first).id)
        f.controller.endSession(); f.controller.beginSession(source: .reopen, context: .ordinary)
        f.controller.panelWillShow()
        try f.waitForFileResult { $0 !== before && $0.launcherItems.isEmpty }
        XCTAssertEqual(f.controller.results.displayCount, 0)
    }
    func testFileFiltersScopeAndModeReopenDoNotReuseLauncherRows() throws {
        let f = try Fixture()
        try f.launcher.add(f.app.url, alias: "regex:ed")
        f.controller.searchField.text = "regex:ed"; f.controller.startSearch()
        try f.waitForFileResult { $0.query.raw == "regex:ed" }
        XCTAssertTrue(try XCTUnwrap(f.controller.results.result).launcherItems.isEmpty)
        try f.launcher.rename(try XCTUnwrap(f.launcher.aliases.first).id, alias: "alias")
        f.controller.filters.options.kind = 3
        f.controller.searchField.text = "alias"; f.controller.startSearch()
        try f.waitForFileResult { $0.query.raw == "alias" && $0.single?.options.kind == 3 }
        XCTAssertTrue(try XCTUnwrap(f.controller.results.result).launcherItems.isEmpty)
        f.controller.filters.options.kind = nil
        f.controller.setDirectoryScope(f.root)
        try f.waitForFileResult { $0.directoryScope != nil }
        XCTAssertTrue(try XCTUnwrap(f.controller.results.result).launcherItems.isEmpty)
        f.controller.setDirectoryScope(nil)
        f.controller.searchField.text = "Editor"; f.controller.setSearchMode(.application)
        try f.waitForFileResult { $0.query.raw == "Editor" && $0.single?.options.kind == 2 }
        f.controller.additionalSources = { [store = f.store] in [SearchSource(id: "startup", displayName: "", isOnline: true, store: store)] }
        try f.launcher.remove(try XCTUnwrap(f.launcher.aliases.first).id)
        let before = try XCTUnwrap(f.controller.results.result)
        f.controller.beginSession(source: .reopen, context: .ordinary); f.controller.panelWillShow()
        try f.waitForFileResult { $0 !== before && $0.single?.options.kind == nil }
    }
    func testForceFileInputPersistsAcrossSourceRefreshAndClearsOnEdit() throws {
        let f = try Fixture()
        f.controller.searchField.text = "g hello"; f.controller.startSearch()
        let fileButton = try XCTUnwrap(f.controller.view.subviews.compactMap { $0 as? NSButton }.first { $0.action == #selector(SearchViewController.forceFileSearch) })
        XCTAssertTrue(fileButton.isEnabled); XCTAssertFalse(fileButton.isHidden)
        fileButton.performClick(nil)
        try f.waitForFileResult { $0.query.raw == "g hello" }
        let beforeRefresh = try XCTUnwrap(f.controller.results.result)
        f.controller.sourcesChanged()
        try f.waitForFileResult { $0 !== beforeRefresh && $0.query.raw == "g hello" }
        guard case .files(let raw) = f.controller.queryRoute else { return XCTFail() }
        XCTAssertEqual(raw, "g hello")
        f.controller.searchField.text = "g other"; f.controller.startSearch()
        guard case .web = f.controller.queryRoute else { return XCTFail() }
    }
    func testSaveKeepsDirectoryResultsUntilExplicitModeSwitch() throws {
        let f = try Fixture()
        f.controller.beginSession(source: .hotkey, context: SearchContext(mode: .save, target: nil, directoryScope: nil))
        f.controller.searchField.text = "g hello"; f.controller.startSearch()
        try f.waitForFileResult { $0.query.raw == "g hello" }
        guard case .files = f.controller.queryRoute else { return XCTFail() }
        XCTAssertEqual(f.controller.results.result?.single?.options.kind, 1)
        XCTAssertTrue(f.opened.isEmpty)
        let old = try f.request()
        f.controller.setSearchMode(.ordinary)
        guard case .web = f.controller.queryRoute else { return XCTFail() }
        XCTAssertEqual(f.controller.actionExecutor.execute(old), .cancelled(.staleSession))
    }
    func testApplicationModeFiltersIndexedHitsAndAddsAliases() throws {
        let f = try Fixture()
        try f.launcher.add(f.app.url, alias: "ed")
        f.controller.searchField.text = "ed"; f.controller.setSearchMode(.application)
        try f.waitForFileResult { $0.query.raw == "ed" }
        XCTAssertEqual(f.controller.results.result?.single?.options.kind, 2)
        XCTAssertEqual(f.controller.results.displayCount, 1)
        XCTAssertEqual(f.controller.results.selectedItem?.kind, 2)
    }
    func testApplicationUsesCapturedURLAndEmitsAcceptanceOnlyAfterWorkspaceResponse() throws {
        let f = try Fixture(), request = try f.request()
        XCTAssertNil(f.controller.actionExecutor.execute(request))
        XCTAssertEqual(f.launched, [f.app.url])
        XCTAssertTrue(f.events.isEmpty)
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(.alreadyDispatched))
        f.controller.endSession()
        try XCTUnwrap(f.completion)(true); try XCTUnwrap(f.completion)(true)
        XCTAssertEqual(f.events.map(\.outcome), [.accepted])
    }
    func testStaleMissingReplacedAndChangedBundleApplicationsNeverDispatch() throws {
        for reason in 0..<4 {
            let f = try Fixture(), request = try f.request()
            switch reason {
            case 0: f.controller.session.queryChanged()
            case 1: try FileManager.default.removeItem(at: f.app.url)
            case 2:
                try FileManager.default.moveItem(at: f.app.url, to: f.root.appendingPathComponent("old.app"))
                try FileManager.default.createDirectory(at: f.app.url, withIntermediateDirectories: true)
            default: f.controller.actionExecutor.system.launcher.bundleIdentifier = { _ in "changed.bundle" }
            }
            XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(reason == 0 ? .staleSession : reason == 2 ? .targetChanged : .applicationUnavailable))
            XCTAssertTrue(f.launched.isEmpty)
        }
    }
    func testMissingAliasRemainsVisibleWithoutAnotherBundleInstallationFallback() throws {
        let f = try Fixture()
        try f.launcher.add(f.app.url, alias: "alias")
        try FileManager.default.removeItem(at: f.app.url)
        guard case .application(let app) = try XCTUnwrap(f.launcher.candidates(for: "alias").first) else { return XCTFail() }
        XCTAssertFalse(app.available)
        XCTAssertEqual(app.url, f.app.url)
        XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(item: .application(app))), .cancelled(.applicationUnavailable))
        XCTAssertTrue(f.launched.isEmpty)
    }
    func testLateWorkspaceResponseCannotHideReopenedSessionAndRejectionIsVisible() throws {
        let f = try Fixture(), request = try f.request()
        var hides = 0; f.controller.hidePanel = { hides += 1 }
        f.controller.actionExecutor.execute(request)
        f.controller.beginSession(source: .reopen, context: .ordinary)
        try XCTUnwrap(f.completion)(true)
        XCTAssertEqual(hides, 0)
        let lateFailure = try f.request()
        f.controller.actionExecutor.execute(lateFailure)
        f.controller.beginSession(source: .reopen, context: .ordinary)
        let footerBeforeFailure = f.controller.footer.text
        try XCTUnwrap(f.completion)(false)
        XCTAssertEqual(f.controller.footer.text, footerBeforeFailure)
        let fresh = try f.request()
        f.controller.actionExecutor.execute(fresh)
        try XCTUnwrap(f.completion)(false)
        XCTAssertEqual(f.events.map(\.outcome), [.accepted, .failed(.systemRejected), .failed(.systemRejected)])
        XCTAssertEqual(hides, 0)
    }
    func testInvalidWebURLAndContextRestrictionsBlockDispatch() throws {
        let f = try Fixture(), keyword = WebKeyword.defaults[0]
        let invalid = PaletteItem.web(WebPaletteItem(keyword: keyword, text: "hello", url: URL(string: "https://other.example/?q=hello")!))
        XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(item: invalid)), .cancelled(.invalidURL))
        f.controller.setSearchMode(.save)
        XCTAssertEqual(f.controller.actionExecutor.execute(try f.request()), .cancelled(.contextUnavailable))
        XCTAssertTrue(f.opened.isEmpty); XCTAssertTrue(f.launched.isEmpty)
    }
    func testLauncherCellsClearFileMetadataAndUseRealTargetDescription() throws {
        let f = try Fixture(), cell = ResultCell(frame: NSRect(x: 0, y: 0, width: 760, height: 50))
        let file = try XCTUnwrap(f.controller.results.selectedItem)
        cell.configure(file, query: .parse("txt"), icons: f.controller.results.icons)
        let labels = cell.subviews.compactMap { $0 as? NSTextField }
        XCTAssertEqual(labels.count, 5)
        guard labels.count == 5 else { return }
        XCTAssertFalse(labels[3].stringValue.isEmpty)
        cell.configure(.application(f.app), icons: f.controller.results.icons)
        XCTAssertEqual(labels[2].stringValue, f.app.url.path)
        XCTAssertEqual(labels[3].stringValue, ""); XCTAssertEqual(labels[4].stringValue, "")
        guard case .web(let web) = QueryRouter(keywords: WebKeyword.defaults).route("g hello", mode: .ordinary) else { return XCTFail() }
        cell.configure(.web(web), icons: f.controller.results.icons)
        XCTAssertEqual(labels[2].stringValue, L10n.text("launcher.web", "Google"))
        XCTAssertEqual(labels[3].stringValue, ""); XCTAssertEqual(labels[4].stringValue, "")
        XCTAssertEqual(cell.toolTip, web.url.absoluteString)
    }
    func testWaitingCommandHasNoActionAndIndexProgressCannotReplaceWebResult() throws {
        let f = try Fixture()
        f.controller.searchField.text = "g "; f.controller.startSearch()
        XCTAssertEqual(f.controller.results.displayCount, 0)
        f.controller.performAction(.open)
        XCTAssertTrue(f.opened.isEmpty)
        f.controller.searchField.text = "g hello"; f.controller.startSearch()
        let identity = f.controller.results.selectedPaletteItem?.identity
        f.controller.managerStateChanged(.scanning)
        f.controller.performAction(.open)
        XCTAssertEqual(f.controller.results.selectedPaletteItem?.identity, identity)
        XCTAssertEqual(f.opened.count, 1)
    }
    func testApplicationMenuKeepsTargetAndOffersOnlySupportedActionsAndDrag() throws {
        let f = try Fixture()
        f.controller.results.showCommands([.application(f.app)])
        XCTAssertNotNil(f.controller.results.onPasteboardWriter?(0))
        let menu = f.controller.contextMenu()
        XCTAssertEqual(menu.items.count, f.app.available ? 5 : 0)
        var copies: [URL] = []
        f.controller.actionExecutor.system.copy = { _, url, _ in copies.append(url); return true }
        let copy = try XCTUnwrap(menu.items.first { ($0.representedObject as? PaletteActionRequest)?.action == .copyPath })
        f.controller.results.showCommands([])
        f.controller.paletteContextAction(copy)
        XCTAssertEqual(copies, [f.app.url])
        XCTAssertNil(f.controller.actionExecutor.capture(.preview, paletteItem: .application(f.app)))
        XCTAssertNil(f.controller.actionExecutor.capture(.trash, paletteItem: .application(f.app)))
    }
    func testMarkedTextDoesNotDispatchDisplayedCommand() throws {
        let f = try Fixture()
        f.controller.searchField.text = "g hello"; f.controller.startSearch()
        let menu = f.controller.contextMenu()
        f.controller.searchField.editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        f.controller.startSearch(); f.controller.performAction(.open); f.controller.paletteContextAction(menu.items[0])
        XCTAssertTrue(f.opened.isEmpty)
        XCTAssertTrue(f.launched.isEmpty)
    }
}
