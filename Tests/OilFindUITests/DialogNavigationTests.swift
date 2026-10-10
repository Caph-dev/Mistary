import Foundation
import XCTest
@testable import OilFindApp

final class DialogNavigationTests: XCTestCase {
    private final class Permission: AccessibilityPermissionChecking {
        private let lock = NSLock()
        private var trusted = true
        private(set) var prompts = 0
        var granted: Bool {
            get { lock.lock(); defer { lock.unlock() }; return trusted }
            set { lock.lock(); trusted = newValue; lock.unlock() }
        }
        func isTrusted() -> Bool { granted }
        func requestTrust() -> Bool { prompts += 1; return granted }
    }

    private final class Client: DialogAccessibilityClient {
        private let lock = NSLock()
        private var recorded: [String] = []
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
        var onCall: ((String) throws -> Void)?
        var directory = URL(fileURLWithPath: "/tmp/before")
        var filename: String? = "keep 文档.txt"
        var selected: URL?
        var failure: DialogFailure?
        var hostFocused = true
        var helperPID: Int32 = 10
        var selectSupported = false
        var ignoreDirectoryWrite = false
        var changedFilename = false
        var target: DialogTarget?

        private func call(_ name: String, _ context: DialogCallContext) throws {
            XCTAssertFalse(Thread.isMainThread)
            try context.check()
            lock.lock(); recorded.append(name); lock.unlock()
            try onCall?(name)
            try context.check()
        }
        func capture(mode: DialogMode, generation: UUID, context: DialogCallContext) throws -> DialogTarget {
            try call("capture", context)
            let value = DialogTarget(hostPID: 10, accessibilityPID: helperPID, windowIdentity: UUID(),
                                     panelIdentity: UUID(), mode: mode, generation: generation)
            target = value
            return value
        }
        func validate(_ target: DialogTarget, allowMistaryFocus: Bool, context: DialogCallContext) throws {
            try call("validate:\(allowMistaryFocus)", context)
            if let failure { throw failure }
            guard self.target?.generation == target.generation,
                  self.target?.panelIdentity == target.panelIdentity else { throw DialogFailure.targetReplaced }
            if !hostFocused && !allowMistaryFocus { throw DialogFailure.unexpectedFocus }
        }
        func handoff(_ target: DialogTarget, context: DialogCallContext) throws {
            try call("handoff", context); hostFocused = true
        }
        func preparePathControl(_ target: DialogTarget, context: DialogCallContext) throws { try call("pathControl", context) }
        func observe(_ target: DialogTarget, context: DialogCallContext) throws -> DialogObservation {
            try call("observe", context)
            return .init(directory: directory, filename: filename, selectedFile: selected)
        }
        func writeDirectory(_ url: URL, target: DialogTarget, context: DialogCallContext) throws {
            try call("writeDirectory", context)
            if !ignoreDirectoryWrite { directory = url.resolvingSymlinksInPath() }
        }
        func confirmDirectory(_ target: DialogTarget, context: DialogCallContext) throws {
            try call("confirmDirectory", context)
            if changedFilename { filename = "unexpected.txt" }
        }
        func selectFile(_ url: URL, target: DialogTarget, context: DialogCallContext) throws {
            try call("selectFile", context)
            guard selectSupported else { throw DialogFailure.selectionUnsupported }
            selected = url
        }
    }

    private func execute(_ client: Client, permission: Permission = Permission(), mode: DialogMode = .open,
                         directory: URL = URL(fileURLWithPath: "/tmp/space 中文"), file: URL? = nil,
                         timeout: TimeInterval = 1) -> DialogNavigationResult {
        let done = expectation(description: "navigation completion")
        let navigator = DialogNavigation(client: client, permissions: permission, stepTimeout: timeout)
        var result: DialogNavigationResult!
        navigator.start(directory: directory, file: file, mode: mode) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 3)
        return result
    }

    private func drain(_ navigator: DialogNavigation, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(1)
        while navigator.isBusy && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertFalse(navigator.isBusy, file: file, line: line)
    }

    func testPermissionDenialDispatchesNothingAndNeverPrompts() {
        let client = Client(), permission = Permission()
        permission.granted = false
        let result = execute(client, permission: permission)
        XCTAssertEqual(result.state, .failed(.permissionDenied))
        XCTAssertEqual(client.calls, [])
        XCTAssertEqual(permission.prompts, 0)
        _ = permission.requestTrust()
        XCTAssertEqual(permission.prompts, 1)
        XCTAssertFalse(permission.isTrusted())
    }

    func testExpectedMistaryToOriginalFocusHandoffAndHelperProcess() {
        let client = Client()
        client.hostFocused = false; client.helperPID = 20
        let result = execute(client)
        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(result.history, [.captured, .validated, .targetReady, .pathControl, .navigating, .verified])
        XCTAssertEqual(result.target?.hostPID, 10)
        XCTAssertEqual(result.target?.accessibilityPID, 20)
        XCTAssertEqual(client.calls.prefix(4), ["capture", "validate:true", "handoff", "validate:false"])
    }

    func testTargetReplacementBeforeWritingCancels() {
        let client = Client()
        client.onCall = { name in if name == "pathControl" { client.failure = .targetReplaced } }
        let result = execute(client)
        XCTAssertEqual(result.state, .cancelled(.targetReplaced))
        XCTAssertFalse(client.calls.contains("writeDirectory"))
    }

    func testPathControlReplacementBetweenWriteAndConfirmationStopsDispatch() {
        let client = Client()
        client.onCall = { name in if name == "writeDirectory" { client.failure = .targetReplaced } }
        let result = execute(client)
        XCTAssertEqual(result.state, .cancelled(.targetReplaced))
        XCTAssertTrue(result.writeMayHaveCompleted)
        XCTAssertFalse(client.calls.contains("confirmDirectory"))
    }

    func testHostExitCancelsBeforeHandoff() {
        let client = Client()
        client.failure = .targetExited
        XCTAssertEqual(execute(client).state, .cancelled(.targetExited))
        XCTAssertFalse(client.calls.contains("handoff"))
    }

    func testUnexpectedFocusAfterHandoffCancelsBeforeWrite() {
        let client = Client()
        client.onCall = { name in if name == "pathControl" { client.hostFocused = false } }
        XCTAssertEqual(execute(client).state, .cancelled(.unexpectedFocus))
        XCTAssertFalse(client.calls.contains("writeDirectory"))
    }

    func testPermissionRevocationDuringPreparationCancels() {
        let client = Client(), permission = Permission()
        client.onCall = { name in if name == "pathControl" { permission.granted = false } }
        XCTAssertEqual(execute(client, permission: permission).state, .cancelled(.permissionRevoked))
        XCTAssertFalse(client.calls.contains("writeDirectory"))
    }

    func testSaveKeepsFilenameAndNeverSelectsOrSubmitsFile() {
        let client = Client()
        let original = client.filename
        let result = execute(client, mode: .save)
        XCTAssertEqual(result.state, .verified)
        XCTAssertEqual(client.filename, original)
        XCTAssertFalse(client.calls.contains("selectFile"))
        XCTAssertEqual(client.calls.filter { $0 == "writeDirectory" }.count, 1)
    }

    func testMissingOrChangedSaveFilenameFailsWithNamedReason() {
        let missing = Client(); missing.filename = nil
        XCTAssertEqual(execute(missing, mode: .save).state, .failed(.invalidControl))
        XCTAssertFalse(missing.calls.contains("writeDirectory"))
        let changed = Client(); changed.changedFilename = true
        XCTAssertEqual(execute(changed, mode: .save).state, .failed(.filenameChanged))
        XCTAssertFalse(changed.calls.contains("selectFile"))
    }

    func testNoIndependentDirectoryChangeDoesNotVerifyNavigation() {
        let client = Client(); client.ignoreDirectoryWrite = true
        XCTAssertEqual(execute(client).state, .failed(.directoryNotVerified))
    }

    func testOpenFileSelectionReportsUnsupportedSeparately() {
        let client = Client()
        let result = execute(client, file: URL(fileURLWithPath: "/tmp/space 中文/sample.txt"))
        XCTAssertEqual(result.state, .verified)
        XCTAssertFalse(result.fileSelection)
        XCTAssertEqual(result.selectionFailure, .selectionUnsupported)
        let supported = Client(); supported.selectSupported = true
        let selected = execute(supported, file: URL(fileURLWithPath: "/tmp/space 中文/sample.txt"))
        XCTAssertEqual(selected.state, .verified)
        XCTAssertTrue(selected.fileSelection)
    }

    func testSaveRejectsFileSelectionBeforeCapture() {
        let client = Client()
        XCTAssertEqual(execute(client, mode: .save, file: URL(fileURLWithPath: "/tmp/file")).state, .failed(.invalidControl))
        XCTAssertEqual(client.calls, [])
    }

    func testCancellationDuringDispatchedWriteDoesNotReviveOrDispatchMoreCalls() {
        let client = Client(), permission = Permission()
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "write dispatched")
        let done = expectation(description: "cancelled completion")
        let returned = expectation(description: "late response returned")
        client.onCall = { name in
            if name == "writeDirectory" {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 2)
                returned.fulfill()
            }
        }
        let navigator = DialogNavigation(client: client, permissions: permission)
        var completions = 0
        navigator.start(directory: URL(fileURLWithPath: "/tmp/sample"), mode: .open) { result in
            completions += 1
            XCTAssertEqual(result.state, .cancelled(.cancelled))
            XCTAssertTrue(result.writeMayHaveCompleted)
            done.fulfill()
        }
        wait(for: [entered], timeout: 1)
        navigator.cancel()
        wait(for: [done], timeout: 1)
        let calls = client.calls
        let busy = expectation(description: "old IPC still occupies worker")
        navigator.start(directory: URL(fileURLWithPath: "/tmp/sample"), mode: .open) { result in
            XCTAssertEqual(result.state, .failed(.busy)); busy.fulfill()
        }
        wait(for: [busy], timeout: 1)
        release.signal()
        wait(for: [returned], timeout: 1)
        drain(navigator)
        XCTAssertEqual(client.calls, calls)
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(client.calls.contains("confirmDirectory"))
    }

    func testTimeoutCompletesOnMainWhileReadResponseIsStillBlocked() {
        let client = Client()
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "capture dispatched")
        let returned = expectation(description: "capture returned")
        client.onCall = { name in
            if name == "capture" {
                entered.fulfill(); _ = release.wait(timeout: .now() + 2); returned.fulfill()
            }
        }
        let done = expectation(description: "watchdog completion")
        let navigator = DialogNavigation(client: client, permissions: Permission(), stepTimeout: 0.05)
        navigator.start(directory: URL(fileURLWithPath: "/tmp/sample"), mode: .open) { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(result.state, .failed(.timedOut))
            XCTAssertFalse(result.writeMayHaveCompleted)
            done.fulfill()
        }
        wait(for: [entered, done], timeout: 1)
        let before = client.calls
        release.signal()
        wait(for: [returned], timeout: 1)
        drain(navigator)
        XCTAssertEqual(client.calls, before)
        XCTAssertEqual(client.calls, ["capture"])
    }

    func testTimedOutWriteReportsUnknownOutcomeAndDoesNotRetry() {
        let client = Client()
        let release = DispatchSemaphore(value: 0)
        let returned = expectation(description: "write returned")
        client.onCall = { name in
            if name == "writeDirectory" { _ = release.wait(timeout: .now() + 2); returned.fulfill() }
        }
        let done = expectation(description: "unknown outcome")
        let navigator = DialogNavigation(client: client, permissions: Permission(), stepTimeout: 0.05)
        var result: DialogNavigationResult!
        navigator.start(directory: URL(fileURLWithPath: "/tmp/sample"), mode: .open) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(result.state, .failed(.resultUnknown))
        XCTAssertTrue(result.writeMayHaveCompleted)
        let before = client.calls
        release.signal()
        wait(for: [returned], timeout: 1)
        drain(navigator)
        XCTAssertEqual(client.calls, before)
        XCTAssertEqual(client.calls.filter { $0 == "writeDirectory" }.count, 1)
        XCTAssertFalse(client.calls.contains("confirmDirectory"))
    }

    func testWatchdogBoundsBlockedResponseEvenWhenInjectedClockDoesNotAdvance() {
        let client = Client()
        let release = DispatchSemaphore(value: 0)
        client.onCall = { name in if name == "capture" { _ = release.wait(timeout: .now() + 2) } }
        let done = expectation(description: "wall-clock deadline")
        let navigator = DialogNavigation(client: client, permissions: Permission(), stepTimeout: 0.05, now: { 0 })
        navigator.start(directory: URL(fileURLWithPath: "/tmp/sample"), mode: .open) { result in
            XCTAssertEqual(result.state, .failed(.timedOut)); done.fulfill()
        }
        wait(for: [done], timeout: 1)
        release.signal()
        drain(navigator)
        XCTAssertEqual(client.calls, ["capture"])
    }

    func testSecureOrUnsupportedControlFailsWithoutWriting() {
        for reason in [DialogFailure.secureInput, .unsupportedControl, .invalidControl] {
            let client = Client()
            client.onCall = { name in if name == "pathControl" { throw reason } }
            XCTAssertEqual(execute(client).state, .failed(reason))
            XCTAssertFalse(client.calls.contains("writeDirectory"))
        }
    }

    func testOriginalPanelClosedAfterNavigationCannotBecomeVerified() {
        let client = Client()
        client.onCall = { name in if name == "confirmDirectory" { client.failure = .targetReplaced } }
        XCTAssertEqual(execute(client).state, .cancelled(.targetReplaced))
        XCTAssertFalse(client.calls.contains("selectFile"))
    }

    func testInjectedDeadlineExpiresWithoutWaitingForWallClock() {
        let context = DialogCallContext(deadline: 5, now: { 6 }, cancellation: { nil })
        XCTAssertThrowsError(try context.check()) { XCTAssertEqual($0 as? DialogFailure, .timedOut) }
        XCTAssertEqual(context.remaining, 0)
    }

    #if DEBUG
    func testProbeParsingRequiresExplicitTargetsAndDoesNotCombinePromptWithNavigation() throws {
        XCTAssertThrowsError(try AXProbe.parse(["--ax-probe", "inspect"]))
        XCTAssertThrowsError(try AXProbe.parse(["--ax-probe", "inspect", "--pid", "10", "--request-permission"]))
        XCTAssertThrowsError(try AXProbe.parse(["--ax-probe", "navigate", "--pid", "10", "--directory", "/tmp"]))
        XCTAssertThrowsError(try AXProbe.parse(["--ax-probe", "permissions", "--timeout", "nan"]))
        let options = try AXProbe.parse(["--ax-probe", "permissions", "--request-permission"])
        XCTAssertTrue(options.prompt)
        XCTAssertNil(options.pid)
        XCTAssertEqual(try AXProbe.parse(["--ax-probe", "inspect", "--pid", "10"]).pid, 10)
    }

    func testProbeFixturesIncludeSpacesChineseAndSafeSymlink() throws {
        let root = try AXProbe.makeFixtures()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("space 中文")
        let link = root.appendingPathComponent("linked folder")
        let file = directory.appendingPathComponent("sample # 文档.txt")
        try AXProbe.validateFixture(directory: directory, file: file)
        try AXProbe.validateFixture(directory: link, file: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(link.resolvingSymlinksInPath(), directory.resolvingSymlinksInPath())
        XCTAssertThrowsError(try AXProbe.validateFixture(directory: URL(fileURLWithPath: NSHomeDirectory()), file: nil))
        let client = Client()
        XCTAssertEqual(execute(client, mode: .save, directory: link).state, .verified)
    }
    #else
    func testReleaseRejectsAXDebugArgumentsBeforeNormalStartup() {
        XCTAssertThrowsError(try Application.validateArguments(["--ax-probe", "permissions"]))
    }
    #endif
}
