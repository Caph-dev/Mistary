import AppKit
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class PanelBehaviorTests: XCTestCase {
    private let primary = PanelScreen(identity: "primary", frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: NSRect(x: 0, y: 30, width: 1440, height: 845))
    private let secondary = PanelScreen(identity: "secondary", frame: NSRect(x: -1920, y: -200, width: 1920, height: 1080), visibleFrame: NSRect(x: -1920, y: -170, width: 1920, height: 1025))
    private final class Resolver: ContextResolving {
        var captures = 0
        var context = SearchContext(mode: .save, target: SearchContextTarget(processID: 123, bundleIdentifier: "fixture.app", windowIdentity: UUID()), directoryScope: nil)
        var delayed = false
        var completions: [(SearchContext) -> Void] = []
        func capture(source: PanelSource) -> SearchContext { captures += 1; return context }
        func capture(source: PanelSource, completion: @escaping (SearchContext) -> Void) {
            captures += 1
            if delayed { completions.append(completion) } else { completion(context) }
        }
    }
    private func panel(keepOpen: Bool = true, resolver: Resolver = Resolver()) -> SearchPanel {
        _ = NSApplication.shared
        let preferences = PanelPreferences(); preferences.keepOpen = keepOpen
        return SearchPanel(snapshot: true, contextResolver: resolver, preferences: preferences)
    }
    private func assertContained(_ frame: NSRect?, in visible: NSRect, file: StaticString = #filePath, line: UInt = #line) throws {
        let frame = try XCTUnwrap(frame, file: file, line: line)
        XCTAssertTrue(visible.contains(frame), "\(frame) outside \(visible)", file: file, line: line)
    }
    func testDefaultTransientModeAndPlacementCenterWithinVisibleScreen() throws {
        let preferences = PanelPreferences()
        XCTAssertFalse(preferences.keepOpen)
        let frame = try XCTUnwrap(preferences.restoredFrame(screens: [primary], mouse: .zero))
        XCTAssertEqual(frame.size, NSSize(width: 800, height: 560))
        XCTAssertEqual(frame.midY, primary.visibleFrame.midY)
        try assertContained(frame, in: primary.visibleFrame)
    }
    func testModeAndNegativeCoordinatePlacementPersistAcrossInstances() throws {
        let suite = "PanelBehavior-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PanelPreferences(defaults: defaults)
        let frame = NSRect(x: -1700, y: -100, width: 800, height: 560)
        preferences.keepOpen = true; preferences.save(frame: frame, screens: [primary, secondary])
        let reloaded = PanelPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.keepOpen)
        XCTAssertEqual(reloaded.restoredFrame(screens: [secondary, primary], mouse: .zero), frame)
        XCTAssertNil(defaults.object(forKey: "NSWindow Frame"))
    }
    func testScreenRemovalAndMainScreenReorderRecoverVisibleFrame() throws {
        let preferences = PanelPreferences()
        preferences.save(frame: NSRect(x: -1800, y: -100, width: 800, height: 560), screens: [primary, secondary])
        try assertContained(preferences.restoredFrame(screens: [primary], mouse: .zero), in: primary.visibleFrame)
        try assertContained(preferences.restoredFrame(screens: [secondary, primary], mouse: .zero), in: secondary.visibleFrame)
    }
    func testResolutionAndScaleChangesClampPositionAndSize() throws {
        let preferences = PanelPreferences()
        preferences.save(frame: NSRect(x: 900, y: 200, width: 800, height: 560), screens: [primary])
        let smaller = PanelScreen(identity: primary.identity, frame: NSRect(x: 0, y: 0, width: 640, height: 480), visibleFrame: NSRect(x: 0, y: 20, width: 640, height: 440))
        let frame = try XCTUnwrap(preferences.restoredFrame(screens: [smaller], mouse: .zero))
        XCTAssertEqual(frame.size, NSSize(width: 640, height: 440))
        try assertContained(frame, in: smaller.visibleFrame)
    }
    func testSmallStoredFrameHasReasonableMinimumAndFitsTinyDisplay() throws {
        let preferences = PanelPreferences()
        preferences.save(frame: NSRect(x: 20, y: 30, width: 1, height: 1), screens: [primary])
        XCTAssertEqual(preferences.restoredFrame(screens: [primary], mouse: .zero)?.size, NSSize(width: 480, height: 360))
        let tiny = PanelScreen(identity: "tiny", frame: NSRect(x: 0, y: 0, width: 300, height: 200), visibleFrame: NSRect(x: 0, y: 0, width: 300, height: 200))
        try assertContained(preferences.restoredFrame(screens: [tiny], mouse: .zero), in: tiny.visibleFrame)
    }
    func testNoScreensDelaysRestorationWithoutLosingPlacement() throws {
        let preferences = PanelPreferences(), frame = NSRect(x: 100, y: 100, width: 800, height: 560)
        preferences.save(frame: frame, screens: [primary])
        XCTAssertNil(preferences.restoredFrame(screens: [], mouse: .zero))
        preferences.save(frame: .zero, screens: [])
        XCTAssertEqual(preferences.restoredFrame(screens: [primary], mouse: .zero), frame)
        var screens: [PanelScreen] = []
        let tested = SearchPanel(snapshot: true, preferences: preferences, screens: { screens })
        defer { tested.close() }
        tested.show(source: .indexing)
        XCTAssertFalse(tested.isVisible)
        screens = [primary]
        tested.show(source: .indexing)
        XCTAssertTrue(tested.isVisible); XCTAssertEqual(tested.frame, frame)
    }
    func testCorruptedPreferencesUseSafeDefaultsAndRejectInvalidWrites() throws {
        let suite = "PanelBehavior-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "panelKeepOpen")
        defaults.set(Data("invalid".utf8), forKey: "panelPlacement")
        let preferences = PanelPreferences(defaults: defaults)
        XCTAssertFalse(preferences.keepOpen)
        try assertContained(preferences.restoredFrame(screens: [primary], mouse: .zero), in: primary.visibleFrame)
        preferences.save(frame: NSRect(x: CGFloat.infinity, y: 0, width: 800, height: 560), screens: [primary])
        XCTAssertEqual(defaults.data(forKey: "panelPlacement"), Data("invalid".utf8))
        defaults.set(Data(#"{"x":0,"y":0,"width":-1,"height":560,"screen":"primary"}"#.utf8), forKey: "panelPlacement")
        try assertContained(preferences.restoredFrame(screens: [primary], mouse: .zero), in: primary.visibleFrame)
    }
    func testOnlyDedicatedHandleMovesWindowAndDragPersists() {
        let tested = panel(); defer { tested.close() }
        tested.show(source: .indexing); tested.contentView?.layoutSubtreeIfNeeded()
        let controller = tested.searchController
        XCTAssertTrue(tested.isMovable); XCTAssertFalse(tested.isMovableByWindowBackground)
        XCTAssertTrue(tested.styleMask.contains(.nonactivatingPanel)); XCTAssertFalse(tested.canBecomeMain)
        XCTAssertTrue(tested.collectionBehavior.contains(.fullScreenAuxiliary))
        let handlePoint = controller.view.convert(NSPoint(x: controller.dragHandle.frame.midX, y: controller.dragHandle.frame.midY), to: controller.view.superview)
        XCTAssertTrue(controller.view.hitTest(handlePoint) === controller.dragHandle)
        XCTAssertFalse(controller.dragHandle.frame.intersects(controller.results.frame))
        let frame = NSRect(x: 100, y: 100, width: 800, height: 560)
        tested.setFrame(frame, display: false); tested.rememberPlacement()
        XCTAssertEqual(tested.preferences.restoredFrame(screens: PanelScreen.current, mouse: .zero), frame)
    }
    func testOrdinaryBlurHidesTransientButKeepsPersistentAndRevokesDialog() {
        for keepOpen in [false, true] {
            let tested = panel(keepOpen: keepOpen); defer { tested.close() }
            tested.show(source: .hotkey)
            let token = tested.searchController.session.token
            tested.resignKey(); tested.searchController.hideIfInactive()
            if keepOpen {
                XCTAssertTrue(tested.isVisible); XCTAssertFalse(tested.hiding)
                XCTAssertTrue(tested.searchController.session.isActive)
                XCTAssertFalse(tested.searchController.session.contextAvailable)
                XCTAssertNil(tested.searchController.session.context.target)
                XCTAssertFalse(tested.searchController.session.isCurrent(token))
                XCTAssertEqual(tested.searchController.dialogHint.stringValue, L10n.text("panel.contextUnavailable"))
                tested.searchController.session.setMode(.ordinary)
                XCTAssertTrue(tested.searchController.session.isCurrent(tested.searchController.session.token))
            } else { XCTAssertFalse(tested.searchController.session.isActive); XCTAssertTrue(tested.hiding) }
        }
    }
    func testMenuAndDraggingProtectBlurUntilInteractionEnds() {
        for keepOpen in [false, true] {
            for menu in [false, true] {
                let tested = panel(keepOpen: keepOpen); defer { tested.close() }
                tested.show(source: .hotkey)
                let controller = tested.searchController, token = controller.session.token
                let trackingMenu = NSMenu()
                if menu { controller.menuWillOpen(trackingMenu) } else { controller.results.onDragging?(true) }
                tested.resignKey(); controller.hideIfInactive()
                XCTAssertFalse(tested.hiding); XCTAssertTrue(controller.session.isCurrent(token))
                if menu { controller.menuDidClose(trackingMenu) } else { controller.results.onDragging?(false) }
                controller.hideIfInactive()
                XCTAssertFalse(controller.session.isCurrent(token))
            }
        }
    }
    func testExpectedHandoffPreservesCurrentContext() {
        let tested = panel(); defer { tested.close() }
        tested.show(source: .hotkey)
        let token = tested.searchController.session.token
        tested.hide(endingSession: false)
        XCTAssertTrue(tested.searchController.session.isCurrent(token))
        tested.resumeDialog()
        XCTAssertTrue(tested.searchController.session.isCurrent(token))
        XCTAssertTrue(tested.searchController.session.contextAvailable); XCTAssertFalse(tested.hiding)
    }
    func testEscapeCommandWAndRepeatedHotkeyExplicitlyClosePersistentPanel() {
        for key in ["escape", "w", "hotkey"] {
            let tested = panel(); defer { tested.close() }
            tested.show(source: .hotkey); tested.makeKey()
            if key == "hotkey" { tested.toggle() }
            else {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: key == "w" ? .command : [], timestamp: 0, windowNumber: tested.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "w" ? 13 : 53)!
                XCTAssertTrue(tested.searchController.handleKey(event))
            }
            XCTAssertFalse(tested.searchController.session.isActive); XCTAssertTrue(tested.hiding)
        }
    }
    func testAnimationReversalRepeatedToggleRetainsVisibleInputFocus() {
        let tested = panel(); defer { tested.close() }
        tested.show(source: .indexing)
        for _ in 0..<10 { tested.toggle(); tested.toggle() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        XCTAssertFalse(tested.hiding); XCTAssertTrue(tested.isVisible); XCTAssertTrue(tested.isKeyWindow)
        XCTAssertNotNil(tested.searchController.searchField.input.currentEditor())
        XCTAssertEqual(tested.alphaValue, 1)
    }
    func testGlobalInvocationRecapturesVisibleNonKeyPersistentPanelOnly() {
        let resolver = Resolver(), tested = panel(resolver: resolver); defer { tested.close() }
        tested.show(source: .hotkey)
        let token = tested.searchController.session.token
        tested.show(source: .menu)
        XCTAssertEqual(resolver.captures, 1)
        tested.resignKey(); tested.searchController.hideIfInactive()
        resolver.context = .ordinary
        tested.toggle(source: .hotkey)
        XCTAssertEqual(resolver.captures, 2)
        XCTAssertNotEqual(tested.searchController.session.sessionID, token.sessionID)
        XCTAssertEqual(tested.searchController.session.context.mode, .ordinary)
    }
    func testDelayedCaptureCannotReviveHiddenOrNewerPresentation() {
        let resolver = Resolver(); resolver.delayed = true
        let tested = panel(resolver: resolver); defer { tested.close() }
        tested.show(source: .hotkey); tested.hide()
        resolver.completions[0](resolver.context)
        XCTAssertFalse(tested.isVisible); XCTAssertFalse(tested.searchController.session.isActive)
        tested.show(source: .hotkey); tested.show(source: .reopen)
        resolver.completions[2](.ordinary)
        resolver.completions[1](resolver.context)
        XCTAssertEqual(tested.searchController.session.context.mode, .ordinary)
        XCTAssertTrue(tested.isVisible)
    }
    func testActionTimeExpiryWithoutTimerRejectsOldContextAndSubmission() {
        var now = Date(timeIntervalSince1970: 100)
        let session = SearchSession(now: { now }); session.contextLifetime = 120
        session.begin(source: .hotkey, context: Resolver().context)
        let token = session.token
        now.addTimeInterval(119); XCTAssertTrue(session.isCurrent(token))
        now.addTimeInterval(2); XCTAssertFalse(session.isCurrent(token))
        XCTAssertFalse(session.contextAvailable); XCTAssertNil(session.context.target)
        XCTAssertFalse(session.submitContext(Resolver().context, for: token))
        session.setMode(.ordinary); XCTAssertTrue(session.isCurrent(session.token))
        session.begin(source: .hotkey, context: Resolver().context)
        XCTAssertTrue(session.contextAvailable); XCTAssertTrue(session.isCurrent(session.token))
    }
    func testExpiryClearsPreparedPathAndStopsCopyOrNewNavigation() throws {
        let tested = panel(); defer { tested.close() }
        tested.show(source: .hotkey)
        let controller = tested.searchController, adapter = controller.actionExecutor.dialog
        let token = controller.session.token
        _ = adapter.navigate(directory: URL(fileURLWithPath: "/fixture"), file: nil, context: nil, token: token, isCurrent: { controller.session.isCurrent(token) }, completion: { _ in })
        XCTAssertNotNil(adapter.path)
        var copies = 0
        controller.actionExecutor.system.copy = { _, _, _ in copies += 1; return true }
        controller.session.contextLifetime = -1
        controller.copyDialogPath()
        XCTAssertEqual(copies, 0); XCTAssertNil(adapter.path); XCTAssertNil(adapter.token)
        XCTAssertFalse(controller.dialogCopyButton.isEnabled)
        XCTAssertFalse(controller.session.isCurrent(controller.session.token))
    }
    private func prepareFile(in controller: SearchViewController) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PanelBehavior-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("fixture.txt"))
        let config = IndexConfig(rootPath: root.path)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        try controller.prepareSnapshot(state: "results", query: "txt", options: .init(), store: store, selection: 0)
        return root
    }
    func testPreparedManualPathSurvivesPanelHandoffAndResume() throws {
        let resolver = Resolver(); resolver.context = SearchContext(mode: .open, target: nil, directoryScope: nil)
        let tested = panel(resolver: resolver); defer { tested.close() }
        tested.show(source: .hotkey)
        let controller = tested.searchController
        let root = try prepareFile(in: controller); defer { try? FileManager.default.removeItem(at: root) }
        var copies: [URL] = []
        controller.actionExecutor.system.copy = { _, url, _ in copies.append(url); return true }
        controller.animateOpen = { $0() }
        controller.performAction(.open)
        let token = try XCTUnwrap(controller.actionExecutor.dialog.token)
        XCTAssertTrue(controller.session.isCurrent(token)); XCTAssertTrue(controller.dialogCopyButton.isEnabled)
        tested.hide(endingSession: false); tested.resumeDialog()
        XCTAssertTrue(controller.session.isCurrent(token))
        controller.copyDialogPath(); XCTAssertEqual(copies.map { $0.path }, [root.path])
    }
    func testHandleDragProtectsBothModesUntilDragEnds() {
        for keepOpen in [false, true] {
            let tested = panel(keepOpen: keepOpen); defer { tested.close() }
            tested.show(source: .hotkey)
            let controller = tested.searchController, token = controller.session.token
            controller.dragHandle.onDragging?(true)
            tested.resignKey(); controller.hideIfInactive()
            XCTAssertFalse(tested.hiding); XCTAssertTrue(controller.session.isCurrent(token))
            controller.dragHandle.onDragging?(false)
            XCTAssertFalse(controller.session.isCurrent(token))
        }
    }
    func testInvalidationRejectsNewNavigationAndDelayedOriginalAction() throws {
        let resolver = Resolver(); resolver.context = SearchContext(mode: .open, target: nil, directoryScope: nil)
        let tested = panel(resolver: resolver); defer { tested.close() }
        tested.show(source: .hotkey)
        let controller = tested.searchController
        let root = try prepareFile(in: controller); defer { try? FileManager.default.removeItem(at: root) }
        try controller.favorites.add(root)
        let candidate = try XCTUnwrap(controller.directoryCandidates.first)
        let request = try XCTUnwrap(controller.requestAction(.contextNavigation))
        var delayed: (() -> Void)?
        controller.animateOpen = { delayed = $0 }
        controller.performAction(.open)
        controller.session.invalidateContext()
        try XCTUnwrap(delayed)()
        XCTAssertEqual(controller.actionExecutor.execute(request), .cancelled(.staleSession))
        controller.navigateDirectory(candidate, token: controller.session.token)
        XCTAssertNil(controller.actionExecutor.dialog.path)
        XCTAssertNil(controller.actionExecutor.dialog.token)
        XCTAssertFalse(controller.dialogCopyButton.isEnabled)
    }
    func testSettingsUseInjectedPreferencesAndCloseEndsSession() {
        let preferences = PanelPreferences()
        let settings = SettingsModel(snapshot: true, panelPreferences: preferences)
        XCTAssertFalse(settings.panelKeepOpen)
        settings.setPanelKeepOpen(true); XCTAssertTrue(preferences.keepOpen)
        let tested = panel(); tested.show(source: .hotkey); tested.close()
        XCTAssertFalse(tested.searchController.session.isActive)
    }
}
