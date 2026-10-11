import AppKit
import Darwin
import XCTest
@testable import OilFindApp
@testable import OilFindCore

final class FileActionsTests: XCTestCase {
    private final class Fixture {
        let root: URL, store: IndexStore, controller: SearchViewController
        init(name: String = "original.txt", symlink: Bool = false) throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryMutation-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("preserved".utf8).write(to: root.appendingPathComponent(name))
            if symlink { try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent(name)) }
            let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
            store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
            controller = SearchViewController(snapshot: true)
            try controller.prepareSnapshot(state: "results", query: symlink ? "link.txt" : name, options: .init(), store: store, selection: 0)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func mutation(_ action: FileAction = .rename) throws -> FileMutation {
            FileMutation(request: try XCTUnwrap(controller.requestAction(action)))
        }
    }
    func testInvalidLeafNamesCannotMutate() throws {
        let f = try Fixture(), mutation = try f.mutation()
        for name in ["", ".", "..", "a/b", "a:b", "a\0b", String(repeating: "a", count: 256)] {
            XCTAssertEqual(FileActions.performNow(mutation, name: name), .failed(.invalidName))
        }
        XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
    }
    func testRenameAndDirectoryCreationAreVerifiedAndPreserveContents() throws {
        let f = try Fixture(), mutation = try f.mutation()
        XCTAssertEqual(FileActions.performNow(mutation, name: "新 ' $ ` folder.txt"), .verified)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("新 ' $ ` folder.txt"), encoding: .utf8), "preserved")
        let g = try Fixture(), creation = try g.mutation(.createDirectory)
        XCTAssertEqual(FileActions.performNow(creation, name: "new folder"), .verified)
        XCTAssertTrue((try f.root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        XCTAssertTrue((try g.root.appendingPathComponent("new folder").resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
    }
    func testExistingDestinationAndConcurrentDestinationNeverOverwrite() throws {
        for concurrent in [false, true] {
            let f = try Fixture(), mutation = try f.mutation(), destination = f.root.appendingPathComponent("occupied.txt")
            var system = FileMutationSystem()
            if concurrent { system.beforeOperation = { try! Data("other".utf8).write(to: destination) } }
            else { try Data("other".utf8).write(to: destination) }
            XCTAssertEqual(FileActions.performNow(mutation, name: "occupied.txt", system: system), .failed(.destinationExists))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "other")
            XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
        }
    }
    func testCreateDirectoryConflictIncludesDanglingSymlinkAndRace() throws {
        for variant in 0..<3 {
            let f = try Fixture(), mutation = try f.mutation(.createDirectory), destination = f.root.appendingPathComponent("occupied")
            var system = FileMutationSystem()
            if variant == 0 { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false) }
            if variant == 1 { try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: f.root.appendingPathComponent("missing")) }
            if variant == 2 { system.beforeOperation = { try! Data("other".utf8).write(to: destination) } }
            XCTAssertEqual(FileActions.performNow(mutation, name: "occupied", system: system), .failed(.destinationExists))
            XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
        }
    }
    func testSourceDeletionReplacementAndChangesDuringExecutionCancel() throws {
        for variant in 0..<3 {
            let f = try Fixture(), mutation = try f.mutation()
            var system = FileMutationSystem()
            let change = {
                try! FileManager.default.moveItem(at: mutation.request.target.url, to: f.root.appendingPathComponent("saved.txt"))
                if variant != 0 { try! Data("replacement".utf8).write(to: mutation.request.target.url) }
            }
            if variant == 2 { system.beforeOperation = change } else { change() }
            XCTAssertEqual(FileActions.performNow(mutation, name: "renamed.txt", system: system), .cancelled(.targetChanged))
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("renamed.txt").path))
            XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("saved.txt"), encoding: .utf8), "preserved")
        }
    }
    func testSymlinksAndMovedParentAreRejected() throws {
        let linked = try Fixture(symlink: true)
        XCTAssertEqual(FileActions.performNow(try linked.mutation(), name: "renamed"), .failed(.symlinkUnsupported))
        let f = try Fixture(), mutation = try f.mutation(), moved = f.root.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        var system = FileMutationSystem()
        system.beforeOperation = { try! FileManager.default.moveItem(at: f.root, to: moved) }
        XCTAssertEqual(FileActions.performNow(mutation, name: "renamed", system: system), .cancelled(.targetChanged))
        XCTAssertEqual(try String(contentsOf: moved.appendingPathComponent("original.txt"), encoding: .utf8), "preserved")
    }
    func testPermissionAndReadOnlyFailuresRetainOriginal() throws {
        for code in [EACCES, EPERM, EROFS] {
            let f = try Fixture(), mutation = try f.mutation()
            var system = FileMutationSystem()
            system.rename = { _, _, _ in errno = code; return -1 }
            XCTAssertEqual(FileActions.performNow(mutation, name: "renamed", system: system), .failed(.permissionDenied))
            XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
        }
    }
    func testUnsupportedExclusiveRenameNeverFallsBack() throws {
        let f = try Fixture(), mutation = try f.mutation()
        var system = FileMutationSystem(), calls = 0
        system.rename = { _, _, _ in calls += 1; errno = ENOTSUP; return -1 }
        XCTAssertEqual(FileActions.performNow(mutation, name: "renamed", system: system), .failed(.unsupportedAction))
        XCTAssertEqual(calls, 1); XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
    }
    func testCaseOnlyRenameFollowsVolumeSemantics() throws {
        let f = try Fixture(), mutation = try f.mutation()
        let destination = f.root.appendingPathComponent("ORIGINAL.TXT")
        let insensitive = FileIdentity.read(destination)?.link == mutation.request.target.identity?.link
        XCTAssertEqual(FileActions.performNow(mutation, name: "ORIGINAL.TXT"), insensitive ? .failed(.caseRenameUnsupported) : .verified)
        XCTAssertEqual(try String(contentsOf: insensitive ? mutation.request.target.url : destination, encoding: .utf8), "preserved")
    }
    func testQueuedOperationRevalidatesDiskAndCapturesOriginalSelection() throws {
        let f = try Fixture(), mutation = try f.mutation()
        let queue = DispatchQueue(label: "fixture.mutation")
        queue.suspend(); defer { queue.resume() }
        f.controller.actionExecutor.fileActions = FileActions(queue: queue)
        let done = expectation(description: "cancel changed original")
        f.controller.onActionEvent = { event in
            XCTAssertEqual(event.outcome, .cancelled(.targetChanged)); done.fulfill()
        }
        f.controller.actionExecutor.execute(mutation, name: "renamed")
        try FileManager.default.moveItem(at: mutation.request.target.url, to: f.root.appendingPathComponent("saved"))
        try Data("replacement".utf8).write(to: mutation.request.target.url)
        f.controller.results.clear()
        queue.resume(); wait(for: [done], timeout: 3); queue.suspend()
        XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "replacement")
    }
    func testOfflineAndExpiredRequestsNeverDispatchMutation() throws {
        for offline in [true, false] {
            let f = try Fixture(), mutation = try f.mutation()
            var calls = 0
            f.controller.actionExecutor.fileActions.system.rename = { _, _, _ in calls += 1; return 0 }
            if offline {
                f.controller.actionExecutor.sources = { [SearchSource(id: "startup", displayName: "", isOnline: false, store: f.store)] }
            } else { f.controller.session.end() }
            f.controller.actionExecutor.execute(mutation, name: "renamed")
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
        }
    }
    func testCompletedMutationStillEmitsVerifiedAfterSessionEnds() throws {
        let f = try Fixture(), mutation = try f.mutation(), queue = DispatchQueue(label: "fixture.finish")
        queue.suspend()
        f.controller.actionExecutor.fileActions = FileActions(queue: queue)
        let done = expectation(description: "real completion")
        f.controller.onActionEvent = { event in XCTAssertEqual(event.outcome, .verified); done.fulfill() }
        f.controller.actionExecutor.fileActions.system.beforeOperation = {
            DispatchQueue.main.sync { f.controller.session.end() }
        }
        f.controller.actionExecutor.execute(mutation, name: "renamed")
        queue.resume()
        wait(for: [done], timeout: 3)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("renamed"), encoding: .utf8), "preserved")
    }
    func testSourceInvalidationDuringQueueWaitCancelsBeforeIO() throws {
        let f = try Fixture(), mutation = try f.mutation(), queue = DispatchQueue(label: "fixture.offline")
        queue.suspend()
        f.controller.actionExecutor.fileActions = FileActions(queue: queue)
        let done = expectation(description: "cancel queued offline source")
        f.controller.onActionEvent = { event in XCTAssertEqual(event.outcome, .cancelled(.sourceUnavailable)); done.fulfill() }
        f.controller.actionExecutor.execute(mutation, name: "renamed")
        f.controller.actionExecutor.sources = { [SearchSource(id: "startup", displayName: "", isOnline: false, store: f.store)] }
        queue.resume(); wait(for: [done], timeout: 3)
        XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
    }
    func testMutationsRefreshExistingFSEventsIndex() throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("MistaryEvents-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let resolved = try XCTUnwrap(realpath(raw.path, nil)); defer { free(resolved) }
        let base = URL(fileURLWithPath: String(cString: resolved)), root = base.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("preserved".utf8).write(to: root.appendingPathComponent("original.txt"))
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let manager = IndexManager(config: config, dbURL: base.appendingPathComponent("index.oilfind"))
        manager.start(); defer { manager.stop() }
        func eventually(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(8)
            while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            return condition()
        }
        XCTAssertTrue(eventually { manager.state == .ready })
        let store = try XCTUnwrap(manager.store), c = SearchViewController(snapshot: true)
        XCTAssertTrue(root.path.hasPrefix("/private/var/"))
        XCTAssertNotNil(store.read { store.resolve(path: root.appendingPathComponent("original.txt").path) })
        try c.prepareSnapshot(state: "results", query: "original.txt", options: .init(), store: store, selection: 0)
        let creation = FileMutation(request: try XCTUnwrap(c.requestAction(.createDirectory)))
        XCTAssertEqual(FileActions.performNow(creation, name: "created"), .verified)
        XCTAssertTrue(eventually { manager.store?.read { manager.store!.resolve(path: root.appendingPathComponent("created").path) != nil } == true })
        let rename = FileMutation(request: try XCTUnwrap(c.requestAction(.rename)))
        XCTAssertEqual(FileActions.performNow(rename, name: "renamed.txt"), .verified)
        XCTAssertTrue(eventually {
            guard let current = manager.store else { return false }
            return current.read {
                current.resolve(path: root.appendingPathComponent("original.txt").path) == nil
                    && current.resolve(path: root.appendingPathComponent("renamed.txt").path) != nil
            }
        })
        XCTAssertEqual(c.actionExecutor.validate(rename.request), .targetChanged)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("renamed.txt"), encoding: .utf8), "preserved")
    }

    func testInvalidationAfterAuthorizationStillCancelsWaitingMutation() throws {
        let f = try Fixture(), mutation = try f.mutation(), queue = DispatchQueue(label: "fixture.second-queue")
        f.controller.actionExecutor.fileActions = FileActions(queue: queue)
        var identityChecks = 0
        f.controller.actionExecutor.system.identity = { url in
            identityChecks += 1
            if identityChecks == 2 {
                // The real executor has just authorized its registered permit.
                queue.suspend()
                DispatchQueue.main.async { f.controller.session.end(); queue.resume() }
            }
            return FileIdentity.read(url)
        }
        let done = expectation(description: "executor cancels between authorization and I/O")
        f.controller.onActionEvent = { event in
            XCTAssertEqual(event.outcome, .cancelled(.staleSession)); done.fulfill()
        }
        f.controller.actionExecutor.execute(mutation, name: "renamed")
        wait(for: [done], timeout: 3)
        XCTAssertEqual(identityChecks, 2)
        XCTAssertEqual(try String(contentsOf: mutation.request.target.url, encoding: .utf8), "preserved")
    }

}
