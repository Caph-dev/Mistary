import Foundation

/// AX sessions never imply that an Open or Save action has been submitted.
enum DialogMode: String { case open, save }

enum DialogFailure: String, Error {
    case permissionDenied, permissionRevoked, targetExited, targetReplaced
    case unexpectedFocus, invalidControl, unsupportedControl, unsupportedDirectoryObservation
    case filenameChanged, directoryNotVerified, selectionUnsupported, timedOut, cancelled
    case systemError, resultUnknown, busy, secureInput
}

enum DialogState: Equatable {
    case captured, validated, targetReady, pathControl, navigating, verified
    case cancelled(DialogFailure), failed(DialogFailure)
    var terminal: Bool {
        switch self { case .verified, .cancelled, .failed: return true; default: return false }
    }
}

struct DialogTarget {
    let hostPID: Int32
    let accessibilityPID: Int32
    let windowIdentity: UUID
    let panelIdentity: UUID
    let mode: DialogMode
    let generation: UUID
}

struct DialogObservation {
    let directory: URL?
    let filename: String?
    let selectedFile: URL?
}

/// Implementations must check this context before every system request, including reads.
final class DialogCallContext {
    let deadline: TimeInterval
    private let now: () -> TimeInterval
    private let cancellation: () -> DialogFailure?
    init(deadline: TimeInterval, now: @escaping () -> TimeInterval,
         cancellation: @escaping () -> DialogFailure?) {
        self.deadline = deadline; self.now = now; self.cancellation = cancellation
    }
    func check() throws {
        if let reason = cancellation() { throw reason }
        if now() >= deadline { throw DialogFailure.timedOut }
    }
    var remaining: TimeInterval { max(0, deadline - now()) }
}

protocol AccessibilityPermissionChecking {
    func isTrusted() -> Bool
    @discardableResult func requestTrust() -> Bool
}

/// This experiment deliberately has no action for submitting an Open/Save panel.
protocol DialogAccessibilityClient: AnyObject {
    func capture(mode: DialogMode, generation: UUID, context: DialogCallContext) throws -> DialogTarget
    func validate(_ target: DialogTarget, allowMistaryFocus: Bool, context: DialogCallContext) throws
    func handoff(_ target: DialogTarget, context: DialogCallContext) throws
    func preparePathControl(_ target: DialogTarget, context: DialogCallContext) throws
    func observe(_ target: DialogTarget, context: DialogCallContext) throws -> DialogObservation
    func writeDirectory(_ url: URL, target: DialogTarget, context: DialogCallContext) throws
    func confirmDirectory(_ target: DialogTarget, context: DialogCallContext) throws
    func selectFile(_ url: URL, target: DialogTarget, context: DialogCallContext) throws
}

struct DialogNavigationResult {
    let state: DialogState
    let history: [DialogState]
    let target: DialogTarget?
    let fileSelection: Bool
    let selectionFailure: DialogFailure?
    /// Cancellation cannot retract a request already handed to the target process.
    let writeMayHaveCompleted: Bool
}

/// One worker is shared by all sessions on this navigator. A cancelled in-flight
/// call must return before another session can start using its client.
final class DialogNavigation {
    private let client: DialogAccessibilityClient
    private let permissions: AccessibilityPermissionChecking
    private let worker = DispatchQueue(label: "me.caph.mistary.ax", qos: .userInitiated)
    private let watchdog = DispatchQueue(label: "me.caph.mistary.ax.deadlines")
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let stepTimeout: TimeInterval
    private var active: Session?
    private var workerBusy = false

    private final class Session {
        let generation: UUID
        var state = DialogState.captured
        var history: [DialogState] = []
        var target: DialogTarget?
        var step = UUID()
        var deadline: TimeInterval = 0
        var dispatchedWrite = false
        var validatePath: () -> DialogFailure? = { nil }
        var selection = false
        var selectionFailure: DialogFailure?
        let completion: (DialogNavigationResult) -> Void
        init(generation: UUID, completion: @escaping (DialogNavigationResult) -> Void) {
            self.generation = generation; self.completion = completion
        }
    }

    init(client: DialogAccessibilityClient, permissions: AccessibilityPermissionChecking,
         stepTimeout: TimeInterval = 2,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        precondition(stepTimeout > 0 && stepTimeout.isFinite)
        self.client = client; self.permissions = permissions
        self.stepTimeout = stepTimeout; self.now = now
    }

    /// Completion is delivered once on the main queue; IPC never runs there.
    func start(directory: URL, file: URL? = nil, mode: DialogMode, target capturedTarget: DialogTarget? = nil,
               validatePath: @escaping () -> DialogFailure? = { nil },
               completion: @escaping (DialogNavigationResult) -> Void) {
        lock.lock()
        guard !workerBusy else {
            lock.unlock()
            DispatchQueue.main.async {
                completion(.init(state: .failed(.busy), history: [.failed(.busy)], target: nil,
                                 fileSelection: false, selectionFailure: nil, writeMayHaveCompleted: false))
            }
            return
        }
        let session = Session(generation: capturedTarget?.generation ?? UUID(), completion: completion)
        session.validatePath = validatePath
        active = session; workerBusy = true
        lock.unlock()
        worker.async { [self] in
            defer {
                lock.lock(); workerBusy = false
                if active === session { active = nil }
                lock.unlock()
            }
            do {
                guard permissions.isTrusted() else { throw DialogFailure.permissionDenied }
                guard directory.isFileURL, file == nil || mode == .open else { throw DialogFailure.invalidControl }
                if let file {
                    guard file.isFileURL,
                          file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
                        throw DialogFailure.invalidControl
                    }
                }
                let target: DialogTarget
                if let capturedTarget { target = capturedTarget }
                else { target = try call(session) { try client.capture(mode: mode, generation: session.generation, context: $0) } }
                guard target.generation == session.generation, target.mode == mode else { throw DialogFailure.targetReplaced }
                lock.lock(); session.target = target; lock.unlock()
                try transition(.captured, session)
                try call(session) { try client.validate(target, allowMistaryFocus: true, context: $0) }
                try transition(.validated, session)
                try call(session) { try client.handoff(target, context: $0) }
                try call(session) { try client.validate(target, allowMistaryFocus: false, context: $0) }
                try transition(.targetReady, session)
                let before = try checked(session, target) { try client.observe(target, context: $0) }
                if mode == .save && before.filename == nil { throw DialogFailure.invalidControl }
                try checked(session, target) { try client.preparePathControl(target, context: $0) }
                try transition(.pathControl, session)
                try checked(session, target, writes: true) { try client.writeDirectory(directory, target: target, context: $0) }
                try checked(session, target, writes: true) { try client.confirmDirectory(target, context: $0) }
                try transition(.navigating, session)
                let after = try checked(session, target) { try client.observe(target, context: $0) }
                guard after.directory?.resolvingSymlinksInPath().standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
                    throw DialogFailure.directoryNotVerified
                }
                if mode == .save && after.filename != before.filename { throw DialogFailure.filenameChanged }
                if let file {
                    do {
                        try checked(session, target, writes: true) { try client.selectFile(file, target: target, context: $0) }
                        let selected = try checked(session, target) { try client.observe(target, context: $0) }
                        guard selected.selectedFile?.standardizedFileURL == file.standardizedFileURL else {
                            throw DialogFailure.selectionUnsupported
                        }
                        lock.lock(); session.selection = true; lock.unlock()
                    } catch DialogFailure.selectionUnsupported {
                        lock.lock(); session.selectionFailure = .selectionUnsupported; lock.unlock()
                    }
                }
                try checked(session, target) { try client.validate(target, allowMistaryFocus: false, context: $0) }
                finish(session, .verified)
            } catch let reason as DialogFailure {
                lock.lock(); let writes = session.dispatchedWrite; lock.unlock()
                let effective: DialogFailure = reason == .timedOut && writes ? .resultUnknown : reason
                let cancelled: Set<DialogFailure> = [.cancelled, .permissionRevoked, .targetExited, .targetReplaced, .unexpectedFocus]
                finish(session, cancelled.contains(effective) ? .cancelled(effective) : .failed(effective))
            } catch { finish(session, .failed(.systemError)) }
        }
    }

    var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return workerBusy
    }

    func cancel() {
        lock.lock(); let session = active; lock.unlock()
        if let session { finish(session, .cancelled(.cancelled)) }
    }

    private func checked<T>(_ session: Session, _ target: DialogTarget, writes: Bool = false,
                            _ body: (DialogCallContext) throws -> T) throws -> T {
        try call(session) { context in
            try client.validate(target, allowMistaryFocus: false, context: context)
            try context.check()
            if writes {
                lock.lock()
                guard !session.state.terminal else { lock.unlock(); throw DialogFailure.cancelled }
                session.dispatchedWrite = true
                lock.unlock()
            }
            return try body(context)
        }
    }

    private func call<T>(_ session: Session, _ body: (DialogCallContext) throws -> T) throws -> T {
        lock.lock()
        guard !session.state.terminal else { lock.unlock(); throw DialogFailure.cancelled }
        let step = UUID(), deadline = now() + stepTimeout
        session.step = step; session.deadline = deadline
        lock.unlock()
        // Dispatch supplies the watchdog's monotonic wall-clock bound. The
        // injectable clock controls synchronous checks, not timer delivery.
        watchdog.asyncAfter(deadline: .now() + stepTimeout) { [self] in
            finish(session, .failed(.timedOut), expectedStep: step)
        }
        let context = DialogCallContext(deadline: deadline, now: now) { [self] in
            lock.lock(); let terminal = session.state.terminal || active !== session; lock.unlock()
            if terminal { return .cancelled }
            if !permissions.isTrusted() { return .permissionRevoked }
            return session.validatePath()
        }
        try context.check()
        let value = try body(context)
        try context.check()
        lock.lock(); session.step = UUID(); lock.unlock()
        return value
    }

    private func transition(_ state: DialogState, _ session: Session) throws {
        lock.lock(); defer { lock.unlock() }
        guard !session.state.terminal else { throw DialogFailure.cancelled }
        session.state = state; session.history.append(state)
    }

    private func finish(_ session: Session, _ requestedState: DialogState, expectedStep: UUID? = nil) {
        lock.lock()
        guard active === session, !session.state.terminal,
              expectedStep == nil || session.step == expectedStep else {
            lock.unlock(); return
        }
        let state: DialogState = requestedState == .failed(.timedOut) && session.dispatchedWrite
            ? .failed(.resultUnknown) : requestedState
        if session.history.last != state { session.history.append(state) }
        session.state = state
        let result = DialogNavigationResult(state: state, history: session.history, target: session.target,
                                           fileSelection: session.selection, selectionFailure: session.selectionFailure,
                                           writeMayHaveCompleted: session.dispatchedWrite)
        // Invalidate the generation even while a cancelled IPC remains in flight.
        active = nil
        lock.unlock()
        DispatchQueue.main.async { session.completion(result) }
    }
}
