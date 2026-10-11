import AppKit
import ApplicationServices
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class DialogWorkflowTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: IndexStore
        let controller: SearchViewController
        var opened: [URL] = []
        var copied: [URL] = []
        var events: [ActionOutcome] = []
        var delayed: (() -> Void)?
        init(mode: SearchMode) throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DialogWorkflow-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent("文档 file.txt"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
            let config = IndexConfig(rootPath: root.path)
            store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
            controller = SearchViewController(snapshot: true)
            controller.beginSession(source: .hotkey, context: SearchContext(mode: mode, target: nil, directoryScope: nil))
            try controller.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0)
            controller.actionExecutor.system.open = { [unowned self] in opened.append($0); return true }
            controller.actionExecutor.system.copy = { [unowned self] _, url, _ in copied.append(url); return true }
            controller.onActionEvent = { [unowned self] in events.append($0.outcome) }
            controller.animateOpen = { [unowned self] in delayed = $0 }
        }
        deinit { controller.endSession(); try? FileManager.default.removeItem(at: root) }
        func activate() throws {
            controller.performAction(.open)
            try XCTUnwrap(delayed)()
        }
    }

    func testOpenManualHandoffDoesNotOpenOrCopyUntilExplicitClick() throws {
        let f = try Fixture(mode: .open)
        try f.activate()
        XCTAssertTrue(f.opened.isEmpty); XCTAssertTrue(f.copied.isEmpty)
        XCTAssertEqual(f.events, [.failed(.dialogManual)])
        XCTAssertEqual(f.controller.actionExecutor.dialog.path?.path, f.root.path)
        XCTAssertFalse(f.controller.dialogHint.isHidden)
        XCTAssertTrue(f.controller.dialogCopyButton.isEnabled)
        f.controller.copyDialogPath()
        XCTAssertEqual(f.copied.map(\.path), [f.root.path])
    }
    func testSaveExplicitFileUsesContainingDirectoryWithoutOpening() throws {
        let f = try Fixture(mode: .save)
        try f.activate()
        XCTAssertEqual(f.controller.actionExecutor.dialog.path?.path, f.root.path)
        XCTAssertTrue(f.opened.isEmpty); XCTAssertTrue(f.copied.isEmpty)
    }
    func testContextNavigationManualAndOrdinaryExitIsExplicit() throws {
        let f = try Fixture(mode: .save)
        let request = try XCTUnwrap(f.controller.requestAction(.contextNavigation))
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .failed(.dialogManual))
        XCTAssertTrue(f.opened.isEmpty)
        f.controller.session.setMode(.ordinary)
        try f.activate()
        XCTAssertEqual(f.opened.count, 1)
        XCTAssertEqual(f.events.last, .accepted)
    }
    func testDelayedActionAfterModeChangeNeverOpens() throws {
        let f = try Fixture(mode: .open)
        f.controller.performAction(.open)
        f.controller.session.setMode(.ordinary)
        try XCTUnwrap(f.delayed)()
        XCTAssertTrue(f.opened.isEmpty)
        XCTAssertEqual(f.events.last, .cancelled(.staleSession))
    }
    func testOfflineAndDeletedOriginalStopBeforeHandoff() throws {
        for offline in [false, true] {
            let f = try Fixture(mode: .open)
            f.controller.performAction(.open)
            if offline {
                f.controller.actionExecutor.sources = { [unowned f] in [SearchSource(id: "startup", displayName: "Fixture", isOnline: false, store: f.store)] }
            } else { try FileManager.default.removeItem(at: f.root.appendingPathComponent("文档 file.txt")) }
            try XCTUnwrap(f.delayed)()
            XCTAssertTrue(f.opened.isEmpty)
            XCTAssertNil(f.controller.actionExecutor.dialog.path)
            XCTAssertEqual(f.events.last, .cancelled(offline ? .sourceUnavailable : .fileUnavailable))
        }
    }
    func testOldRecoveryButtonCannotCopyIntoNewSession() throws {
        let f = try Fixture(mode: .open)
        try f.activate()
        f.controller.beginSession(source: .hotkey, context: .ordinary)
        f.controller.copyDialogPath()
        XCTAssertTrue(f.copied.isEmpty)
        XCTAssertTrue(f.controller.dialogHint.isHidden)
    }
    func testQuickSwitchFavoritePreparesExplicitDirectoryAndKeepsSession() throws {
        let f = try Fixture(mode: .save)
        try f.controller.favorites.add(f.root)
        let candidate = try XCTUnwrap(f.controller.directoryCandidates.first)
        let token = f.controller.session.token
        f.controller.navigateDirectory(candidate, token: token)
        XCTAssertEqual(f.controller.actionExecutor.dialog.path?.path, f.root.path)
        XCTAssertEqual(f.controller.session.token, token)
        XCTAssertTrue(f.opened.isEmpty); XCTAssertTrue(f.copied.isEmpty)
        XCTAssertTrue(f.controller.directoryMenu().items.contains { $0.submenu?.items.contains { $0.identifier?.rawValue == "handoff" } == true })
    }
    func testQuickSwitchRejectsRemovedFavoriteAndExpiredFinder() throws {
        let f = try Fixture(mode: .open)
        try f.controller.favorites.add(f.root)
        let favorite = try XCTUnwrap(f.controller.directoryCandidates.first)
        try f.controller.favorites.remove(try XCTUnwrap(f.controller.favorites.favorites.first).id)
        f.controller.navigateDirectory(favorite, token: f.controller.session.token)
        XCTAssertNil(f.controller.actionExecutor.dialog.path)
        let finder = FinderDirectory(windowIdentity: UUID(), directoryURL: f.root, observedAt: Date().addingTimeInterval(-121), method: .accessibility)
        f.controller.beginSession(source: .hotkey, context: SearchContext(mode: .open, target: nil, directoryScope: nil, recentFinderDirectory: finder))
        f.controller.navigateDirectory(try XCTUnwrap(f.controller.directoryCandidates.first), token: f.controller.session.token)
        XCTAssertNil(f.controller.actionExecutor.dialog.path)
    }
    func testNoProductionApprovalsOrUnknownTargetDispatch() throws {
        let f = try Fixture(mode: .open)
        var constructed = 0
        f.controller.actionExecutor.dialog.makeNavigator = { _ in constructed += 1; return nil }
        XCTAssertTrue(f.controller.actionExecutor.dialog.capabilities.isEmpty)
        try f.activate()
        XCTAssertEqual(constructed, 0)
    }
    func testSaveDefaultsToFoldersAndDisablesLauncherRouting() throws {
        let f = try Fixture(mode: .save)
        f.controller.searchField.text = "folder"
        f.controller.startSearch()
        let deadline = Date().addingTimeInterval(2)
        while f.controller.results.result?.query.raw != "folder" && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(f.controller.results.result?.query.raw, "folder")
        XCTAssertEqual(f.controller.results.selectedItem?.kind, 1)
        if case .files(let input) = f.controller.queryRoute { XCTAssertEqual(input, "folder") }
        else { XCTFail("Save mode must keep file routing") }
    }
    func testFailureReasonsHaveBothLocalizations() {
        let reasons: [DialogFailure] = [.permissionDenied, .permissionRevoked, .targetExited, .targetReplaced, .unexpectedFocus, .invalidControl, .unsupportedControl, .unsupportedDirectoryObservation, .filenameChanged, .directoryNotVerified, .selectionUnsupported, .timedOut, .cancelled, .systemError, .resultUnknown, .busy, .secureInput]
        let previous = L10n.snapshotChinese
        defer { L10n.snapshotChinese = previous }
        for chinese in [false, true] {
            L10n.snapshotChinese = chinese
            for reason in reasons { XCTAssertFalse(L10n.text(DialogWorkflowStatus.failed(reason).localizationKey).isEmpty) }
        }
    }
    private final class Permission: AccessibilityPermissionChecking {
        var trusted = true
        func isTrusted() -> Bool { trusted }
        func requestTrust() -> Bool { XCTFail("Navigation must not prompt"); return trusted }
    }
    private final class Client: DialogAccessibilityClient {
        let original: DialogTarget
        var directory: URL
        var filename: String? = ""
        var calls: [String] = []
        var onValidate: ((DialogCallContext) throws -> Void)?
        init(target: DialogTarget, directory: URL) { original = target; self.directory = directory }
        func capture(mode: DialogMode, generation: UUID, context: DialogCallContext) throws -> DialogTarget {
            XCTFail("Must use pre-panel target"); throw DialogFailure.targetReplaced
        }
        func validate(_ target: DialogTarget, allowMistaryFocus: Bool, context: DialogCallContext) throws {
            try context.check(); calls.append("validate"); try onValidate?(context)
            guard target.panelIdentity == original.panelIdentity, target.windowIdentity == original.windowIdentity else { throw DialogFailure.targetReplaced }
        }
        func handoff(_ target: DialogTarget, context: DialogCallContext) throws { try context.check(); calls.append("handoff") }
        func preparePathControl(_ target: DialogTarget, context: DialogCallContext) throws { try context.check(); calls.append("pathControl") }
        func observe(_ target: DialogTarget, context: DialogCallContext) throws -> DialogObservation {
            try context.check(); return .init(directory: directory, filename: filename, selectedFile: nil)
        }
        func writeDirectory(_ url: URL, target: DialogTarget, context: DialogCallContext) throws { try context.check(); calls.append("writeDirectory"); directory = url }
        func confirmDirectory(_ target: DialogTarget, context: DialogCallContext) throws { try context.check(); calls.append("confirmDirectory") }
        func selectFile(_ url: URL, target: DialogTarget, context: DialogCallContext) throws { throw DialogFailure.selectionUnsupported }
    }
    private func approved(_ mode: DialogMode, root: URL) -> (DialogAdapter, DialogContext, SearchContextTarget, Client, Permission, DialogNavigation) {
        let permission = Permission()
        let capability = DialogCapability(bundleIdentifier: "fixture", applicationVersion: "1", systemVersion: "fixture OS", profileID: "fixture-profile", mode: mode, selectsFiles: false)
        let target = DialogTarget(hostPID: 12, accessibilityPID: 12, windowIdentity: UUID(), panelIdentity: UUID(), mode: mode, generation: UUID())
        let client = Client(target: target, directory: root)
        let navigator = DialogNavigation(client: client, permissions: permission)
        let adapter = DialogAdapter(permissions: permission, capabilities: [capability], enabled: { true })
        adapter.environmentMatches = { _, _ in true }
        adapter.makeNavigator = { _ in navigator }
        return (adapter, DialogContext(mode: mode, target: target, capability: capability), SearchContextTarget(processID: 12, bundleIdentifier: "fixture", windowIdentity: target.windowIdentity), client, permission, navigator)
    }
    func testApprovedSaveUsesOriginalTargetAndPreservesEmptyFilename() throws {
        let f = try Fixture(mode: .save)
        let (adapter, context, host, client, _, navigator) = approved(.save, root: f.root)
        let done = expectation(description: "verified Save directory")
        let token = f.controller.session.token
        XCTAssertEqual(adapter.navigate(directory: f.root.appendingPathComponent("folder"), file: nil, context: context, token: token, host: host, isCurrent: { true }) { outcome in
            XCTAssertEqual(outcome, .verified); done.fulfill()
        }, .accepted)
        wait(for: [done], timeout: 3)
        XCTAssertEqual(adapter.status, .navigated)
        XCTAssertEqual(client.filename, "")
        XCTAssertEqual(client.calls.filter { $0 == "writeDirectory" }.count, 1)
        XCTAssertFalse(client.calls.contains("capture"))
        let deadline = Date().addingTimeInterval(1)
        while navigator.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertFalse(navigator.isBusy)
    }
    func testApprovedOpenReportsDirectoryReadyWithoutClaimingSelection() throws {
        let f = try Fixture(mode: .open)
        let (adapter, context, host, _, _, _) = approved(.open, root: f.root)
        let done = expectation(description: "directory ready")
        _ = adapter.navigate(directory: f.root, file: f.root.appendingPathComponent("文档 file.txt"), context: context, token: f.controller.session.token, host: host, isCurrent: { true }) { outcome in
            XCTAssertEqual(outcome, .verified); done.fulfill()
        }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(adapter.status, .directoryReady)
    }
    func testApprovedGateRejectsPermissionAndHostAndEnvironmentChanges() throws {
        for reason in 0..<3 {
            let f = try Fixture(mode: .save)
            let (adapter, context, host, client, permission, _) = approved(.save, root: f.root)
            if reason == 0 { permission.trusted = false }
            if reason == 2 { adapter.environmentMatches = { _, _ in false } }
            let capturedHost = reason == 1 ? SearchContextTarget(processID: 99, bundleIdentifier: "fixture", windowIdentity: host.windowIdentity) : host
            let outcome = adapter.navigate(directory: f.root, file: nil, context: context, token: f.controller.session.token, host: capturedHost, isCurrent: { true }) { _ in XCTFail("No async work should start") }
            XCTAssertEqual(outcome, .failed(.dialogFailed)); XCTAssertTrue(client.calls.isEmpty)
        }
    }
    func testQuickSwitchRejectsChangedRecentFinderEvenInsideFreshnessWindow() throws {
        let f = try Fixture(mode: .open)
        let finder = FinderDirectory(windowIdentity: UUID(), directoryURL: f.root, observedAt: Date(), method: .accessibility)
        f.controller.beginSession(source: .hotkey, context: SearchContext(mode: .open, target: nil, directoryScope: nil, recentFinderDirectory: finder, finderDirectoryIsCurrent: { false }))
        f.controller.navigateDirectory(try XCTUnwrap(f.controller.directoryCandidates.first), token: f.controller.session.token)
        XCTAssertNil(f.controller.actionExecutor.dialog.path)
    }
    func testRecognitionRequiresPermissionAndOnlyReadsCapturedHost() {
        var reads = 0
        let recognition = SystemDialogRecognition(trusted: { false }, frontmostPID: { 1 }, readAttribute: { _, _, _ in reads += 1; return nil })
        var delivered = false
        recognition.capture(processID: 1) { XCTAssertNil($0); delivered = true }
        XCTAssertTrue(delivered); XCTAssertEqual(reads, 0)
        let changed = SystemDialogRecognition(trusted: { true }, frontmostPID: { 2 }, readAttribute: { _, _, _ in XCTFail("Unknown host read"); return nil })
        let done = expectation(description: "changed host")
        changed.capture(processID: 1) { XCTAssertNil($0); done.fulfill() }
        wait(for: [done], timeout: 2)
    }
    func testReadOnlyRecognitionRequiresDialogBrowserAndUnambiguousMode() {
        for variant in 0..<4 {
            let window = AXUIElementCreateApplication(101), browser = AXUIElementCreateApplication(102), button = AXUIElementCreateApplication(103), other = AXUIElementCreateApplication(104)
            let recognition = SystemDialogRecognition(trusted: { true }, frontmostPID: { 100 }, readAttribute: { element, name, _ in
                XCTAssertFalse(Thread.isMainThread)
                if name == kAXFocusedWindowAttribute { return window }
                if name == kAXRoleAttribute {
                    if CFEqual(element, window) { return (variant == 3 ? kAXWindowRole : kAXSheetRole) as CFString }
                    if CFEqual(element, browser) { return (variant == 2 ? kAXGroupRole : kAXBrowserRole) as CFString }
                    return kAXButtonRole as CFString
                }
                if name == kAXChildrenAttribute && CFEqual(element, window) { return [browser, button, other] as CFArray }
                if name == kAXTitleAttribute {
                    return (CFEqual(element, button) ? "Save" : (variant == 1 ? "Open" : "Cancel")) as CFString
                }
                return nil
            })
            let done = expectation(description: "recognition")
            recognition.capture(processID: 100) { mode in
                XCTAssertEqual(mode, variant == 0 ? .save : nil); done.fulfill()
            }
            wait(for: [done], timeout: 2)
        }
    }

    func testCancelledAdapterDropsLateWorkerResultAndSendsNoHandoff() throws {
        let f = try Fixture(mode: .save)
        let (adapter, context, host, client, _, navigator) = approved(.save, root: f.root)
        let blocked = expectation(description: "blocked validation")
        let release = DispatchSemaphore(value: 0)
        client.onValidate = { _ in blocked.fulfill(); _ = release.wait(timeout: .now() + 2) }
        var callbacks = 0
        _ = adapter.navigate(directory: f.root, file: nil, context: context, token: f.controller.session.token, host: host, isCurrent: { true }) { _ in callbacks += 1 }
        wait(for: [blocked], timeout: 1)
        adapter.cancel(); release.signal()
        let deadline = Date().addingTimeInterval(1)
        while navigator.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertFalse(navigator.isBusy)
        XCTAssertEqual(callbacks, 0)
        XCTAssertEqual(adapter.status, .failed(.cancelled))
        XCTAssertFalse(client.calls.contains("handoff"))
        XCTAssertFalse(client.calls.contains("writeDirectory"))
    }
    private final class DelayedResolver: ContextResolving {
        var completions: [(SearchContext) -> Void] = []
        func capture(source: PanelSource) -> SearchContext { XCTFail("Must use async capture"); return .ordinary }
        func capture(source: PanelSource, completion: @escaping (SearchContext) -> Void) { completions.append(completion) }
    }
    func testLateRecognitionCannotShowAfterHideOrReplaceNewInvocation() {
        _ = NSApplication.shared
        let resolver = DelayedResolver(), panel = SearchPanel(snapshot: true, contextResolver: resolver)
        defer { panel.close() }
        panel.show(source: .hotkey)
        XCTAssertFalse(panel.searchController.session.isActive)
        panel.show(source: .hotkey)
        XCTAssertEqual(resolver.completions.count, 2)
        resolver.completions[0](SearchContext(mode: .save, target: nil, directoryScope: nil))
        XCTAssertFalse(panel.isVisible)
        panel.hide()
        resolver.completions[1](SearchContext(mode: .open, target: nil, directoryScope: nil))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.searchController.session.isActive)
        panel.show(source: .hotkey)
        panel.show(source: .hotkey)
        resolver.completions[3](SearchContext(mode: .save, target: nil, directoryScope: nil))
        let current = panel.searchController.session.token
        XCTAssertTrue(panel.isVisible)
        resolver.completions[2](SearchContext(mode: .open, target: nil, directoryScope: nil))
        XCTAssertEqual(panel.searchController.session.context.mode, .save)
        XCTAssertEqual(panel.searchController.session.token, current)
        panel.hide()
    }
    func testRecognitionDeadlineDropsLateReadAndDeliversOnce() {
        let returned = expectation(description: "IPC returned")
        let done = expectation(description: "watchdog delivered")
        let release = DispatchSemaphore(value: 0)
        let recognition = SystemDialogRecognition(trusted: { true }, frontmostPID: { 1 }, readAttribute: { _, _, _ in
            _ = release.wait(timeout: .now() + 2)
            returned.fulfill(); return nil
        })
        var deliveries = 0
        recognition.capture(processID: 1) { mode in XCTAssertNil(mode); deliveries += 1; done.fulfill() }
        wait(for: [done], timeout: 1.5)
        release.signal(); wait(for: [returned], timeout: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(deliveries, 1)
    }

    func testRecognitionCannotCombineBrowserAndButtonFromDifferentSheets() {
        let window = AXUIElementCreateApplication(101), first = AXUIElementCreateApplication(102), second = AXUIElementCreateApplication(103), browser = AXUIElementCreateApplication(104), button = AXUIElementCreateApplication(105)
        let recognition = SystemDialogRecognition(trusted: { true }, frontmostPID: { 100 }, readAttribute: { element, name, _ in
            if name == kAXFocusedWindowAttribute { return window }
            if name == kAXRoleAttribute {
                if CFEqual(element, window) { return kAXWindowRole as CFString }
                if CFEqual(element, first) || CFEqual(element, second) { return kAXSheetRole as CFString }
                return (CFEqual(element, browser) ? kAXBrowserRole : kAXButtonRole) as CFString
            }
            if name == kAXChildrenAttribute {
                if CFEqual(element, window) { return [first, second] as CFArray }
                if CFEqual(element, first) { return [browser] as CFArray }
                if CFEqual(element, second) { return [button] as CFArray }
            }
            if name == kAXTitleAttribute { return "Save" as CFString }
            return nil
        })
        let done = expectation(description: "cross-container evidence rejected")
        recognition.capture(processID: 100) { XCTAssertNil($0); done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testManualRecoveryLayoutAndBothLanguages() throws {
        let language = L10n.snapshotChinese
        defer { L10n.snapshotChinese = language }
        for chinese in [true, false] {
            L10n.snapshotChinese = chinese
            let f = try Fixture(mode: .open)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = f.controller
            window.appearance = NSAppearance(named: chinese ? .aqua : .darkAqua)
            try f.activate()
            f.controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 460)
            f.controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(f.controller.view.bounds.width, 720)
            XCTAssertGreaterThanOrEqual(f.controller.results.frame.minY, f.controller.dialogCopyButton.frame.maxY)
            XCTAssertLessThanOrEqual(f.controller.dialogPath.frame.maxX, f.controller.dialogCopyButton.frame.minX)
            XCTAssertLessThanOrEqual(f.controller.dialogHint.frame.maxY, f.controller.dialogPath.frame.minY)
            XCTAssertTrue(f.controller.dialogCopyButton.isEnabled)
            if let output = ProcessInfo.processInfo.environment["MISTARY_DIALOG_SNAPSHOT_DIR"] {
                let view = f.controller.view
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                window.appearance?.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                let url = URL(fileURLWithPath: output).appendingPathComponent(chinese ? "handoff-zh.png" : "handoff-en.png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            }
            window.close()
        }
    }

}
