import AppKit
import XCTest
@testable import OilFindCore
@testable import OilFindApp

final class ActionExecutorTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let store: IndexStore
        let controller: SearchViewController
        var sources: [SearchSource]
        var dispatched: [(FileAction, URL)] = []
        var events: [ActionEvent] = []
        var delayed: (() -> Void)?
        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryActions-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
            let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
            store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
            controller = SearchViewController(snapshot: true)
            try controller.prepareSnapshot(state: "results", query: "txt", options: .init(sort: .name), store: store, selection: 0)
            sources = [SearchSource(id: "startup", displayName: "Fixture", isOnline: true, store: store)]
            controller.actionExecutor.sources = { [unowned self] in sources }
            controller.onActionEvent = { [unowned self] in events.append($0) }
            controller.animateOpen = { [unowned self] in delayed = $0 }
            controller.actionExecutor.system.open = { [unowned self] in dispatched.append((.open, $0)); return true }
            controller.actionExecutor.system.reveal = { [unowned self] in dispatched.append((.reveal, $0)); return true }
            controller.actionExecutor.system.preview = { [unowned self] in dispatched.append((.preview, $0)); return true }
            controller.actionExecutor.system.copy = { [unowned self] action, url, _ in dispatched.append((action, url)); return true }
            controller.actionExecutor.system.recycle = { [unowned self] url, _ in dispatched.append((.trash, url)) }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func request(_ action: FileAction = .open) throws -> ActionRequest { try XCTUnwrap(controller.requestAction(action)) }
        func source(online: Bool, store replacement: IndexStore? = nil) {
            sources = [SearchSource(id: "startup", displayName: "Fixture", isOnline: online, store: replacement ?? store)]
        }
        func replacementStore() throws -> IndexStore {
            let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
            return IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        }
    }
    func testDelayedOpenExecutesCapturedFileAfterSelectionMoves() throws {
        let f = try Fixture(), original = try f.request()
        f.controller.performAction(.open, request: original)
        f.controller.results.select(1)
        XCTAssertNotEqual(f.controller.results.selectedItem?.path, original.target.url.path)
        try XCTUnwrap(f.delayed)()
        XCTAssertEqual(f.dispatched.map(\.1), [original.target.url])
        XCTAssertEqual(f.events.map(\.outcome), [.accepted])
    }
    func testDelayedOpenDoesNotUseNewSelectionToValidateMissingOriginal() throws {
        let f = try Fixture(), original = try f.request()
        f.controller.performAction(.open, request: original)
        f.controller.results.select(1)
        try FileManager.default.removeItem(at: original.target.url)
        try XCTUnwrap(f.delayed)()
        XCTAssertTrue(f.dispatched.isEmpty)
        XCTAssertEqual(f.events.map(\.outcome), [.cancelled(.fileUnavailable)])
    }
    func testDelayedSourceOfflineAndStoreReplacementCancel() throws {
        for offline in [true, false] {
            let f = try Fixture(), request = try f.request()
            f.controller.performAction(.open, request: request)
            if offline { f.source(online: false) } else { f.source(online: true, store: try f.replacementStore()) }
            try XCTUnwrap(f.delayed)()
            XCTAssertTrue(f.dispatched.isEmpty)
            XCTAssertEqual(f.events.map(\.outcome), [.cancelled(offline ? .sourceUnavailable : .storeReplaced)])
        }
    }
    func testSamePathReplacementIsRejectedEvenWithoutIndexUpdate() throws {
        let f = try Fixture(), request = try f.request()
        f.controller.performAction(.open, request: request)
        let saved = f.root.appendingPathComponent("original.saved")
        try FileManager.default.moveItem(at: request.target.url, to: saved)
        try Data("replacement".utf8).write(to: request.target.url)
        try XCTUnwrap(f.delayed)()
        XCTAssertTrue(f.dispatched.isEmpty)
        XCTAssertEqual(f.events.map(\.outcome), [.cancelled(.targetChanged)])
    }
    func testSymlinkDestinationReplacementIsRejected() throws {
        let f = try Fixture()
        let link = f.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root.appendingPathComponent("a.txt"))
        let replacement = try f.replacementStore()
        f.source(online: true, store: replacement)
        try f.controller.prepareSnapshot(state: "results", query: "link", options: .init(), store: replacement, selection: 0)
        let request = try f.request()
        let destination = f.root.appendingPathComponent("a.txt")
        try FileManager.default.moveItem(at: destination, to: f.root.appendingPathComponent("saved"))
        try Data().write(to: destination)
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(.targetChanged))
        XCTAssertTrue(f.dispatched.isEmpty)
    }
    func testDeletedAndRenamedIndexEntriesCancel() throws {
        for deleted in [true, false] {
            let f = try Fixture(), request = try f.request()
            f.store.write {
                if deleted { _ = f.store.remove(request.target.entryID) }
                else {
                    let name = Array("renamed.txt".utf8)
                    let parent = f.store.parent[Int(request.target.entryID)]
                    _ = f.store.remove(request.target.entryID)
                    name.withUnsafeBufferPointer { bytes in
                        _ = f.store.insert(parent: parent, name: bytes, attrs: EntryAttrs(type: 0, bsdFlags: 0, size: 1, mtime: 0))
                    }
                }
                f.store.version += 1
            }
            XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(.targetChanged))
            XCTAssertTrue(f.dispatched.isEmpty)
        }
    }
    func testUnrelatedIndexVersionChangeKeepsCapturedTargetValid() throws {
        let f = try Fixture(), request = try f.request()
        let other = try XCTUnwrap(f.controller.results.item(at: 1))
        f.store.write { _ = f.store.remove(other.id); f.store.version += 1 }
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .accepted)
        XCTAssertEqual(f.dispatched.map(\.1), [request.target.url])
    }
    func testQueryEndReopenAndSourceChangesCancelPendingOpen() throws {
        for invalidate in [0, 1, 2, 3] {
            let f = try Fixture(), request = try f.request()
            f.controller.performAction(.open, request: request)
            let delayed = try XCTUnwrap(f.delayed)
            switch invalidate {
            case 0: f.controller.startSearch()
            case 1: f.controller.endSession()
            case 2: f.controller.endSession(); f.controller.beginSession(source: .reopen, context: .ordinary)
            default: f.controller.sourcesChanged()
            }
            delayed()
            XCTAssertTrue(f.dispatched.isEmpty)
            XCTAssertEqual(f.events.map(\.outcome), [.cancelled(.staleSession)])
        }
    }
    func testSecondOpenCancelsEarlierAnimationAndDispatchesOnce() throws {
        let f = try Fixture()
        f.controller.performAction(.open)
        let earlier = try XCTUnwrap(f.delayed)
        f.controller.results.select(1)
        let second = try f.request()
        f.controller.performAction(.open, request: second)
        earlier(); try XCTUnwrap(f.delayed)(); try XCTUnwrap(f.delayed)()
        XCTAssertEqual(f.dispatched.map(\.1), [second.target.url])
        XCTAssertEqual(f.events.map(\.outcome), [.cancelled(.superseded), .accepted])
    }
    func testOfflineMetadataCopiesAvoidIOAndOnlineActionsRemainBlocked() throws {
        let f = try Fixture()
        f.source(online: false)
        var reads = 0
        f.controller.actionExecutor.system.identity = { _ in reads += 1; return nil }
        for action in [FileAction.copyPath, .copyName] {
            XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(action)), .verified)
        }
        XCTAssertEqual(reads, 0)
        for action in [FileAction.open, .reveal, .preview, .copyFile, .trash] {
            XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(action)), .cancelled(.sourceUnavailable))
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(f.dispatched.map(\.0), [.copyPath, .copyName])
    }
    func testMenuActionsKeepTargetCapturedWhenMenuWasCreated() throws {
        let f = try Fixture(), menu = f.controller.contextMenu()
        let copy = try XCTUnwrap(menu.items.first { ($0.representedObject as? ActionRequest)?.action == .copyName })
        let original = try XCTUnwrap(copy.representedObject as? ActionRequest)
        f.controller.results.select(1)
        f.controller.contextAction(copy)
        XCTAssertEqual(f.dispatched.map(\.1), [original.target.url])
        let unavailable = try XCTUnwrap(menu.items.last)
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertEqual((unavailable.representedObject as? ActionRequest)?.action, .contextNavigation)
    }
    func testPasteboardFormatsAndCancelledCopyDoesNotClearContents() throws {
        let f = try Fixture(), board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(saved) }
        f.controller.actionExecutor.system.copy = ActionSystem().copy
        for action in [FileAction.copyFile, .copyPath, .copyName] {
            let request = try f.request(action)
            XCTAssertEqual(f.controller.actionExecutor.execute(request), .verified)
            switch action {
            case .copyFile:
                XCTAssertEqual(board.string(forType: .fileURL), request.target.url.absoluteString)
                XCTAssertNil(board.string(forType: .string))
            case .copyPath:
                XCTAssertEqual(board.string(forType: .fileURL), request.target.url.absoluteString)
                XCTAssertEqual(board.string(forType: .string), request.target.url.path)
            default:
                XCTAssertEqual(board.string(forType: .string), request.target.name)
                XCTAssertNil(board.string(forType: .fileURL))
            }
        }
        let stale = try f.request(.copyPath)
        f.controller.session.queryChanged()
        board.clearContents(); board.setString("untouched", forType: .string)
        XCTAssertEqual(f.controller.actionExecutor.execute(stale), .cancelled(.staleSession))
        XCTAssertEqual(board.string(forType: .string), "untouched")
    }
    func testSystemRejectionUnavailableContextAndRequestReplay() throws {
        let f = try Fixture(), request = try f.request()
        f.controller.actionExecutor.system.open = { _ in false }
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .failed(.systemRejected))
        f.controller.session.queryChanged()
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(.alreadyDispatched))
        XCTAssertEqual(f.events.count, 1)
        XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(.contextNavigation)), .cancelled(.contextUnavailable))
        f.controller.actionExecutor.system.copy = { _, _, _ in false }
        XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(.copyPath)), .failed(.clipboardRejected))
    }
    func testDistinctTrashRequestsForSameTargetDispatchOnlyOnceWhileInFlight() throws {
        let f = try Fixture(), first = try f.request(.trash), second = try f.request(.trash)
        XCTAssertNotEqual(first.actionID, second.actionID)
        var calls = 0
        var completion: ((URL?, Error?) -> Void)?
        f.controller.actionExecutor.system.recycle = { _, callback in calls += 1; completion = callback }
        XCTAssertEqual(f.controller.actionExecutor.execute(first), .accepted)
        XCTAssertEqual(f.controller.actionExecutor.execute(second), .cancelled(.alreadyDispatched))
        XCTAssertEqual(calls, 1)
        try XCTUnwrap(completion)(nil, NSError(domain: "fixture", code: 1))
        XCTAssertEqual(f.events.map(\.outcome), [.accepted, .cancelled(.alreadyDispatched), .failed(.systemRejected)])
        // Completion releases the target; a fresh request may now dispatch.
        XCTAssertEqual(f.controller.actionExecutor.execute(try f.request(.trash)), .accepted)
        XCTAssertEqual(calls, 2)
        try XCTUnwrap(completion)(nil, NSError(domain: "fixture", code: 1))
    }
    func testRecycleVerifiedOnceAfterSessionEnds() throws {
        let f = try Fixture(), request = try f.request(.trash)
        var completion: ((URL?, Error?) -> Void)?
        f.controller.actionExecutor.system.recycle = { _, callback in completion = callback }
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .accepted)
        f.controller.endSession()
        let destination = f.root.appendingPathComponent("fake-trash")
        try FileManager.default.moveItem(at: request.target.url, to: destination)
        try XCTUnwrap(completion)(destination, nil)
        try XCTUnwrap(completion)(destination, nil)
        XCTAssertEqual(f.events.map(\.outcome), [.accepted, .verified])
        XCTAssertEqual(Set(f.events.map { $0.request.actionID }).count, 1)
    }
    func testRecycleMappingAloneIsNotVerifiedAndErrorsAreNamed() throws {
        for withError in [false, true] {
            let f = try Fixture(), request = try f.request(.trash)
            f.controller.actionExecutor.system.recycle = { _, callback in
                callback(request.target.url, withError ? NSError(domain: "fixture", code: 1) : nil)
            }
            XCTAssertEqual(f.controller.actionExecutor.execute(request), .accepted)
            XCTAssertEqual(f.events.map(\.outcome), [.accepted, .failed(withError ? .systemRejected : .trashNotVerified)])
        }
    }
    func testMenuAndDragKeepSessionUntilTheirActionsFinish() throws {
        let f = try Fixture()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = f.controller
        defer { window.close() }
        var hides = 0
        f.controller.hidePanel = { hides += 1; f.controller.endSession() }
        let menu = f.controller.contextMenu()
        let copy = try XCTUnwrap(menu.items.first { ($0.representedObject as? ActionRequest)?.action == .copyName })
        let token = f.controller.session.token
        f.controller.menuWillOpen(menu)
        f.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(hides, 0)
        XCTAssertTrue(f.controller.session.isCurrent(token))
        f.controller.menuDidClose(menu)
        f.controller.contextAction(copy)
        XCTAssertEqual(f.dispatched.count, 1)
        XCTAssertEqual(hides, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(hides, 1)
        f.controller.beginSession(source: .hotkey, context: .ordinary)
        f.controller.results.onDragging?(true)
        f.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(hides, 1)
        f.controller.results.onDragging?(false)
        XCTAssertEqual(hides, 2)
    }
    func testLiveEntryWithChangedAncestorPathCancelsRequest() throws {
        let f = try Fixture(), request = try f.request()
        f.store.write { f.store.rebase(to: f.root.appendingPathComponent("moved").path); f.store.version += 1 }
        XCTAssertTrue(f.store.read { f.store.isLive(request.target.entryID) })
        XCTAssertEqual(f.controller.actionExecutor.execute(request), .cancelled(.targetChanged))
        XCTAssertTrue(f.dispatched.isEmpty)
    }
    func testMenuOpenWaitsForAnimationBeforeHidingSession() throws {
        let f = try Fixture()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = f.controller
        defer { window.close() }
        var hides = 0
        f.controller.hidePanel = { hides += 1; f.controller.endSession() }
        let menu = f.controller.contextMenu()
        let open = try XCTUnwrap(menu.items.first { ($0.representedObject as? ActionRequest)?.action == .open })
        let original = try XCTUnwrap(open.representedObject as? ActionRequest)
        f.controller.menuWillOpen(menu)
        f.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        f.controller.menuDidClose(menu)
        f.controller.contextAction(open)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(hides, 0)
        XCTAssertTrue(f.controller.session.isCurrent(original.token))
        f.controller.results.select(1)
        try XCTUnwrap(f.delayed)()
        XCTAssertEqual(f.dispatched.map(\.1), [original.target.url])
        XCTAssertEqual(f.events.map(\.outcome), [.accepted])
        XCTAssertEqual(hides, 1)
    }
    func testOldInactiveCallbackCannotEndReopenedSession() throws {
        let f = try Fixture()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.panelSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = f.controller
        defer { window.close() }
        var hides = 0
        f.controller.hidePanel = { hides += 1; f.controller.endSession() }
        f.controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        f.controller.endSession()
        f.controller.beginSession(source: .reopen, context: .ordinary)
        let token = f.controller.session.token
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(hides, 0)
        XCTAssertTrue(f.controller.session.isCurrent(token))
    }
    func testPreviewProviderStaysBoundToRequestAndRejectsInvalidTarget() throws {
        let f = try Fixture(), request = try f.request(.preview)
        f.controller.performAction(.preview, request: request)
        f.controller.results.select(1)
        XCTAssertEqual(f.controller.quickLook.selectedURL?(), request.target.url)
        f.source(online: false)
        XCTAssertNil(f.controller.quickLook.selectedURL?())
        XCTAssertEqual(f.dispatched.map(\.0), [.preview])
    }
    func testMarkedTextDoesNotTriggerActionMenuOrFileActions() throws {
        let f = try Fixture()
        f.controller.searchField.editor.setMarkedText("拼", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        for (key, code) in [("k", UInt16(40)), ("c", UInt16(8)), ("y", UInt16(16))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                                                     isARepeat: false, keyCode: code))
            XCTAssertFalse(f.controller.handleKey(event))
        }
        XCTAssertTrue(f.dispatched.isEmpty)
    }
}
