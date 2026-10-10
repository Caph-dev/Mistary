import AppKit
import XCTest
@testable import OilFindApp

final class SearchSessionTests: XCTestCase {
    private final class Resolver: ContextResolving {
        var captures: [PanelSource] = []
        var beforeCapture: (() -> Void)?
        var context = SearchContext(mode: .finder, target: SearchContextTarget(processID: 123, bundleIdentifier: "test.finder", windowIdentity: UUID()), directoryScope: URL(fileURLWithPath: "/fixture"))
        func capture(source: PanelSource) -> SearchContext {
            beforeCapture?(); captures.append(source); return context
        }
    }
    func testUserEntrypointsCaptureBeforePanelFocus() {
        _ = NSApplication.shared
        for source in [PanelSource.hotkey, .menu, .reopen] {
            let resolver = Resolver()
            let tested = SearchPanel(snapshot: true, contextResolver: resolver)
            defer { tested.close() }
            resolver.beforeCapture = {
                XCTAssertFalse(tested.isVisible)
                XCTAssertFalse(tested.isKeyWindow)
                XCTAssertNil(tested.searchController.searchField.input.currentEditor())
            }
            let delegate = AppDelegate(panel: tested)
            switch source {
            case .hotkey: delegate.handleHotKey()
            case .menu: delegate.showSearch()
            default: XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
            }
            XCTAssertEqual(resolver.captures, [source])
            XCTAssertEqual(tested.searchController.session.invocationSource, source)
            XCTAssertEqual(tested.searchController.session.context.target, resolver.context.target)
            XCTAssertEqual(tested.searchController.session.context.directoryScope, resolver.context.directoryScope)
        }
    }
    func testVisibleShowAndToggleHideDoNotRecapture() {
        _ = NSApplication.shared
        let resolver = Resolver()
        let tested = SearchPanel(snapshot: true, contextResolver: resolver)
        defer { tested.close() }
        tested.show(source: .hotkey)
        let token = tested.searchController.session.token
        tested.show(source: .menu)
        tested.show(source: .indexing)
        XCTAssertEqual(resolver.captures, [.hotkey])
        XCTAssertEqual(tested.searchController.session.token.sessionID, token.sessionID)
        XCTAssertEqual(tested.searchController.session.context.target, resolver.context.target)
        tested.makeKey()
        XCTAssertTrue(tested.isKeyWindow)
        tested.toggle(source: .hotkey)
        XCTAssertEqual(resolver.captures, [.hotkey])
        XCTAssertFalse(tested.searchController.session.isActive)
        tested.show(source: .reopen)
        XCTAssertEqual(resolver.captures, [.hotkey, .reopen])
        XCTAssertNotEqual(tested.searchController.session.token.sessionID, token.sessionID)
    }
    func testAutomaticAndOnboardingShowsDoNotBindExternalTargets() {
        _ = NSApplication.shared
        for source in [PanelSource.indexing, .welcome, .interaction] {
            let resolver = Resolver(), panel = SearchPanel(snapshot: true, contextResolver: resolver)
            defer { panel.close() }
            panel.show(source: source)
            XCTAssertTrue(resolver.captures.isEmpty)
            XCTAssertNil(panel.searchController.session.context.target)
            XCTAssertEqual(panel.searchController.session.context.mode, .ordinary)
        }
        let resolver = Resolver(), panel = SearchPanel(snapshot: true, contextResolver: resolver)
        defer { panel.close() }
        panel.show(source: .hotkey, captureContext: false)
        XCTAssertTrue(resolver.captures.isEmpty)
        XCTAssertNil(panel.searchController.session.context.target)
    }
    func testUnavailableContextAndUnknownWindowRemainOrdinary() {
        let resolver = ContextResolver(frontmostApplication: { nil })
        XCTAssertEqual(resolver.capture(source: .hotkey).mode, .ordinary)
        XCTAssertNil(resolver.capture(source: .hotkey).target)
        let session = SearchSession()
        session.begin(source: .menu, context: resolver.capture(source: .menu))
        XCTAssertNil(session.context.directoryScope)
    }
    func testGenerationsRejectStaleQueriesAndContextSubmissions() {
        let session = SearchSession(), context = Resolver().context
        session.begin(source: .hotkey, context: context)
        let first = session.token
        session.queryChanged()
        XCTAssertFalse(session.isCurrent(first))
        XCTAssertFalse(session.submitContext(.ordinary, for: first))
        XCTAssertEqual(session.context.target, context.target)
        let second = session.token
        session.invalidateActions()
        XCTAssertFalse(session.isCurrent(second))
        let third = session.token
        XCTAssertTrue(session.submitContext(.ordinary, for: third))
        XCTAssertFalse(session.isCurrent(third))
        let fourth = session.token
        session.end()
        XCTAssertFalse(session.isCurrent(fourth))
        session.begin(source: .reopen, context: context)
        XCTAssertNotEqual(session.token.sessionID, fourth.sessionID)
    }
    func testExpectedHandoffPreservesSessionWhileOrdinaryHideEndsIt() {
        _ = NSApplication.shared
        let panel = SearchPanel(snapshot: true)
        defer { panel.close() }
        panel.show(source: .indexing)
        let token = panel.searchController.session.token
        panel.hide(endingSession: false)
        XCTAssertTrue(panel.searchController.session.isCurrent(token))
        panel.hide()
        XCTAssertFalse(panel.searchController.session.isCurrent(token))
    }
}
