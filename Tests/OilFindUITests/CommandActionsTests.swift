import AppKit
import XCTest
import Darwin
@testable import OilFindApp
@testable import OilFindCore

final class CommandActionsTests: XCTestCase {
    private func definition(_ execution: ActionExecution, types: [ActionItemType] = [.file]) -> ActionDefinition {
        ActionDefinition(id: UUID(), name: "Test", itemTypes: types, modes: SearchMode.allActionModes,
                         permissions: [.processExecution, .fileRead], enabled: true, execution: execution)
    }
    private func binding(_ path: String = "/tmp/a b'\"$`\n中文{name}.txt") -> ActionBinding {
        ActionBinding(type: .file, url: URL(fileURLWithPath: path), name: URL(fileURLWithPath: path).lastPathComponent,
                      directory: URL(fileURLWithPath: "/tmp"))
    }
    func testArgumentsRemainDataAndInsertedPlaceholdersAreNotReinterpreted() throws {
        let b = binding()
        let d = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                                    arguments: ["{path}", "prefix:{name}:{path}", "{directory}", "{url}"], currentDirectory: "{directory}"))
        let invocation = try CommandInvocation(definition: d, binding: b)
        XCTAssertEqual(invocation.arguments, [b.url.path, "prefix:" + b.name + ":" + b.url.path, "/tmp", b.url.absoluteString])
        XCTAssertEqual(invocation.directory?.path, "/tmp")
    }
    func testInvalidDefinitionsAndUnavailablePermissions() throws {
        let b = binding()
        for args in [["{unknown}"], ["{path"], ["a\0b"]] {
            XCTAssertFalse(definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: args, currentDirectory: nil)).isValid)
        }
        let d = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["{path}"], currentDirectory: nil))
        XCTAssertEqual(d.unavailableReason(binding: b, mode: .ordinary, permission: { _ in false }, application: { _ in true }, executable: { _ in true }), .permissionDenied)
        XCTAssertEqual(d.unavailableReason(binding: b, mode: .ordinary, permission: { _ in true }, application: { _ in true }, executable: { _ in false }), .executableUnavailable)
        XCTAssertThrowsError(try CommandInvocation(definition: definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [], currentDirectory: "relative")), binding: b))
    }
    func testHTTPSValuesCannotChangeURLStructure() throws {
        let d = definition(.urlTemplate("https://example.com/open?q={name}&path={path}"))
        XCTAssertTrue(d.isValid)
        let b = binding("/tmp/中文&admin=1+#fragment.txt")
        let url = try d.boundURL(b)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "example.com"); XCTAssertNil(c.fragment)
        XCTAssertEqual(c.queryItems?.map(\.name), ["q", "path"])
        XCTAssertEqual(c.queryItems?.first?.value, b.name)
        XCTAssertFalse(definition(.urlTemplate("https://{name}/open")).isValid)
        XCTAssertFalse(definition(.urlTemplate("http://example.com/open")).isValid)
    }
    func testActionConfigurationRoundTripAndDamagedDocumentPreserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("actions.json"), d = definition(.urlTemplate("https://example.com?q={name}"))
        try ActionDefinitions(url: url).set([d])
        XCTAssertEqual(ActionDefinitions(url: url).actions, [d])
        for text in ["broken", "{\"version\":99,\"actions\":[]}"] {
            let original = Data(text.utf8); try original.write(to: url)
            let store = ActionDefinitions(url: url)
            XCTAssertNotNil(store.error); XCTAssertThrowsError(try store.set([]))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    private func fileController() throws -> (URL, SearchViewController) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: root.appendingPathComponent("test.txt"))
        let config = IndexConfig(rootPath: root.path, indexSystemDirs: true)
        let store = IndexStore(scan: try XCTUnwrap(Scanner(config: config, threads: 1).run()), config: config)
        let controller = SearchViewController(snapshot: true)
        try controller.prepareSnapshot(state: "results", query: "test.txt", options: .init(), store: store, selection: 0)
        return (root, controller)
    }
    func testCapturedDefinitionExplicitExecutionAndOnceOnlyEvents() throws {
        let (root, controller) = try fileController(); defer { try? FileManager.default.removeItem(at: root) }
        let d = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["{path}"], currentDirectory: nil))
        try controller.customActions.set([d])
        var invocations: [CommandInvocation] = [], outcomes: [ActionOutcome] = []
        controller.actionExecutor.runCommand = { invocation, event in
            invocations.append(invocation); event(.started); event(.started)
            event(.finished(CommandResult(exitCode: 0, timedOut: false, stdout: Data(), stderr: Data(), truncated: false)))
            event(.finished(CommandResult(exitCode: 1, timedOut: false, stdout: Data(), stderr: Data(), truncated: false)))
        }
        controller.actionExecutor.onCustomEvent = { outcomes.append($0.outcome) }
        let menu = controller.contextMenu()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Test" })
        XCTAssertTrue(item.isEnabled); XCTAssertTrue(invocations.isEmpty)
        try controller.customActions.set([])
        controller.customContextAction(item); controller.customContextAction(item)
        XCTAssertEqual(invocations.count, 1); XCTAssertEqual(outcomes, [.accepted, .verified])
        XCTAssertEqual(invocations.first?.arguments, [root.appendingPathComponent("test.txt").path])
        controller.searchField.text = "new"; controller.startSearch()
        XCTAssertEqual(invocations.count, 1)
    }
    func testStaleSourceAndChangedFileLaunchNothing() throws {
        for variant in 0..<3 {
            let (root, c) = try fileController(); defer { try? FileManager.default.removeItem(at: root) }
            let file = try XCTUnwrap(c.requestAction(.custom))
            let request = try XCTUnwrap(c.actionExecutor.captureCustom(definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [], currentDirectory: nil)), file: file))
            var calls = 0
            c.actionExecutor.runCommand = { _, _ in calls += 1 }
            if variant == 0 { c.session.queryChanged() }
            if variant == 1 { c.actionExecutor.sources = { [] } }
            if variant == 2 {
                try FileManager.default.moveItem(at: file.target.url, to: root.appendingPathComponent("saved"))
                try Data().write(to: file.target.url)
            }
            c.actionExecutor.execute(request); XCTAssertEqual(calls, 0)
        }
    }
    func testOpenWithUsesExactApplicationAndAcceptanceOnly() throws {
        let (root, c) = try fileController(); defer { try? FileManager.default.removeItem(at: root) }
        let app = URL(fileURLWithPath: "/Applications/Explicit.app")
        c.actionExecutor.system.launcher.isApplication = { $0 == app }
        var called: [(URL, URL)] = [], outcomes: [ActionOutcome] = []
        c.actionExecutor.system.openWith = { file, app, done in called.append((file, app)); done(true) }
        c.actionExecutor.onCustomEvent = { outcomes.append($0.outcome) }
        let file = try XCTUnwrap(c.requestAction(.custom))
        c.actionExecutor.execute(try XCTUnwrap(c.actionExecutor.captureCustom(definition(.application(app)), file: file)))
        XCTAssertEqual(called.first?.0, file.target.url); XCTAssertEqual(called.first?.1, app)
        XCTAssertEqual(outcomes, [.accepted])
    }
    func testTerminalAndWebFileMutationUnavailableWithoutFallback() throws {
        let terminal = definition(.terminal(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")))
        XCTAssertEqual(terminal.unavailableReason(binding: binding(), mode: .ordinary, permission: { _ in true }, application: { _ in true }, executable: { _ in true }), .terminalUnsupported)
        let c = SearchViewController(snapshot: true)
        let web = WebPaletteItem(keyword: WebKeyword.defaults[0], text: "hello", url: WebKeyword.defaults[0].searchURL("hello")!)
        let item = PaletteItem.web(web)
        XCTAssertFalse(item.actions.contains(.rename)); XCTAssertFalse(item.actions.contains(.createDirectory))
        let command = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["{path}"], currentDirectory: nil))
        let request = try XCTUnwrap(c.actionExecutor.captureCustom(command, item: item))
        XCTAssertEqual(c.actionExecutor.validate(request), .unsupportedAction)
    }
    private func run(_ args: [String], executable: String = "/usr/bin/printf", timeout: TimeInterval = 3, limit: Int = 64) throws -> ([String], CommandResult) {
        let d = definition(.command(executable: URL(fileURLWithPath: executable), arguments: args, currentDirectory: nil))
        let invocation = try CommandInvocation(definition: d, binding: binding())
        let done = expectation(description: "process finished")
        var events: [String] = [], result: CommandResult?
        CommandRunner(outputLimit: limit, timeout: timeout).run(invocation) { event in
            switch event {
            case .started: events.append("started")
            case .cancelled: events.append("cancelled"); done.fulfill()
            case .finished(let value): events.append("finished"); result = value; done.fulfill()
            }
        }
        wait(for: [done], timeout: 8)
        return (events, try XCTUnwrap(result))
    }
    func testRealProcessPreservesLiteralArguments() throws {
        let literal = "space ' \" $HOME `touch nope`\n中文"
        let (events, result) = try run(["%s", literal], limit: 1024)
        XCTAssertEqual(events, ["started", "finished"]); XCTAssertEqual(result.outcome, .verified)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), literal)
    }
    func testBothLargeStreamsAreDrainedAndCapped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("output.sh")
        // The test explicitly selects a fixture script; the application never generates one.
        try Data("#!/bin/sh\ni=0\nwhile [ $i -lt 2000 ]; do printf '1234567890123456789012345678901234567890'; printf '1234567890123456789012345678901234567890' >&2; i=$((i+1)); done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let (_, result) = try run([], executable: script.path)
        XCTAssertEqual(result.outcome, .verified); XCTAssertEqual(result.stdout.count, 64); XCTAssertEqual(result.stderr.count, 64); XCTAssertTrue(result.truncated)
    }
    func testTimeoutLaunchFailureAndNonzeroExitHaveDistinctTerminalResults() throws {
        XCTAssertEqual(try run(["2"], executable: "/bin/sleep", timeout: 0.05).1.outcome, .failed(.commandTimedOut))
        let (events, failure) = try run([], executable: "/no/such/program")
        XCTAssertEqual(events, ["finished"]); XCTAssertEqual(failure.outcome, .failed(.commandLaunchFailed))
        XCTAssertEqual(try run([], executable: "/usr/bin/false").1.outcome, .failed(.commandFailed))
    }
    func testIgnoredTerminationIsEscalatedToKillDirectChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("ignore-term.sh"), pidFile = root.appendingPathComponent("pid")
        defer { if let text = try? String(contentsOf: pidFile), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 { _ = kill(pid, SIGKILL) } }
        try Data("#!/bin/sh\ntrap '' TERM\necho $$ > \"$1\"\nwhile :; do :; done\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertEqual(try run([pidFile.path], executable: script.path, timeout: 2).1.outcome, .failed(.commandTimedOut))
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertGreaterThan(pid, 0); XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testInheritedPipesFinishWhileDescendantStillRuns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("inherited.sh"), pidFile = root.appendingPathComponent("pid"), heartbeat = root.appendingPathComponent("heartbeat")
        defer { if let text = try? String(contentsOf: pidFile), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 { _ = kill(pid, SIGTERM) } }
        try Data("#!/bin/sh\n(while :; do printf x >> \"$2\"; /bin/sleep 0.1; done) &\necho $! > \"$1\"\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertEqual(try run([pidFile.path, heartbeat.path], executable: script.path).1.outcome, .verified)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertGreaterThan(pid, 0); XCTAssertEqual(kill(pid, 0), 0)
        let initial = try Data(contentsOf: heartbeat).count
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(try Data(contentsOf: heartbeat).count, initial)
    }
    func testDeniedFileAccessDisablesAndRejectsCustomAction() throws {
        let (root, c) = try fileController(); defer { try? FileManager.default.removeItem(at: root) }
        let d = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: [], currentDirectory: nil))
        c.actionExecutor.system.readable = { _ in false }
        let file = try XCTUnwrap(c.requestAction(.custom)), request = try XCTUnwrap(c.actionExecutor.captureCustom(d, file: file))
        var calls = 0
        c.actionExecutor.runCommand = { _, _ in calls += 1 }
        XCTAssertEqual(c.actionExecutor.validate(request), .permissionDenied)
        c.actionExecutor.execute(request); XCTAssertEqual(calls, 0)
    }

    func testQueuedCommandRevalidatesSessionBeforeLaunchingProcess() throws {
        let (root, c) = try fileController(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "fixture.command-authorization")
        queue.suspend()
        c.actionExecutor.commandRunner = CommandRunner(queue: queue)
        let marker = root.appendingPathComponent("must-not-exist")
        let d = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], currentDirectory: nil))
        let request = try XCTUnwrap(c.actionExecutor.captureCustom(d, file: try XCTUnwrap(c.requestAction(.custom))))
        let done = expectation(description: "queued command cancelled")
        c.actionExecutor.onCustomEvent = { event in XCTAssertEqual(event.outcome, .cancelled(.staleSession)); done.fulfill() }
        c.actionExecutor.execute(request); c.session.end(); queue.resume()
        wait(for: [done], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAuthorizedProcessStartsBeforeBackgroundMonitoringIsEnqueued() throws {
        let d = definition(.command(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], currentDirectory: nil))
        let invocation = try CommandInvocation(definition: d, binding: binding())
        let queue = DispatchQueue(label: "fixture.final-launch")
        let done = expectation(description: "command finishes")
        var authorized = false, started = false
        CommandRunner(queue: queue).run(invocation, authorize: {
            authorized = true; queue.suspend()
            DispatchQueue.main.async {
                // Any new main-thread invalidation can occur only after launch.
                XCTAssertTrue(started)
                queue.resume()
            }
            return nil
        }) { event in
            switch event {
            case .started: XCTAssertTrue(authorized); started = true
            case .finished(let result): XCTAssertEqual(result.outcome, .verified); done.fulfill()
            case .cancelled: XCTFail("Unexpected cancellation"); done.fulfill()
            }
        }
        wait(for: [done], timeout: 4)
    }

}
