import AppKit
import Darwin
import OilFindCore

/// Path copy preserves the existing URL + text format; file copy is URL-only.
enum FileAction: String, CaseIterable {
    case open, reveal, preview, copyFile, copyPath, copyName, trash, contextNavigation, custom, rename, createDirectory
    var requiresOnline: Bool { self != .copyPath && self != .copyName }
}

enum ActionFailure: String, Error {
    case staleSession, sourceUnavailable, storeReplaced, targetChanged, fileUnavailable
    case systemRejected, clipboardRejected, trashNotVerified, contextUnavailable, alreadyDispatched, superseded
    case applicationUnavailable, invalidURL, unsupportedAction, dialogManual, dialogFailed
    case permissionDenied, terminalUnsupported, executableUnavailable, commandLaunchFailed, commandFailed, commandTimedOut
    case commandOutputFailed
    case invalidName, destinationExists, symlinkUnsupported, caseRenameUnsupported, mutationNotVerified
}

enum ActionOutcome: Equatable {
    /// Asynchronous operations may have a terminal event after acceptance.
    /// Workspace and Quick Look acceptance does not prove an external read.
    case accepted
    case verified
    case cancelled(ActionFailure)
    case failed(ActionFailure)
}

struct ActionEvent {
    let request: ActionRequest
    let outcome: ActionOutcome
}

struct FileIdentity: Equatable {
    struct Node: Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int
        let birthNanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec; birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }
    let link: Node
    let destination: Node
    let resolvedPath: String
    static func read(_ url: URL) -> FileIdentity? {
        var link = stat(), destination = stat()
        guard url.path.withCString({ lstat($0, &link) }) == 0,
              url.path.withCString({ stat($0, &destination) }) == 0 else { return nil }
        return FileIdentity(link: Node(link), destination: Node(destination), resolvedPath: url.resolvingSymlinksInPath().path)
    }
}

struct FileTargetSnapshot {
    let sourceID: String
    let sourceName: String
    let wasOnline: Bool
    let store: IndexStore
    let storeVersion: UInt64
    let entryID: UInt32
    let url: URL
    let name: String
    let identity: FileIdentity?
    let isDirectory: Bool
}

fileprivate final class ActionReceipt {
    var dispatched = false
    func consume() -> Bool {
        guard !dispatched else { return false }; dispatched = true; return true
    }
}

struct ActionRequest {
    fileprivate let receipt = ActionReceipt()
    let actionID: UUID
    let token: SearchSessionToken
    let action: FileAction
    let target: FileTargetSnapshot
    let context: SearchContext
}

struct PaletteActionRequest {
    fileprivate let receipt = ActionReceipt()
    let actionID: UUID
    let token: SearchSessionToken
    let action: FileAction
    let item: PaletteItem
    let identity: FileIdentity?
}

struct PaletteActionEvent {
    let request: PaletteActionRequest
    let outcome: ActionOutcome
}

/// All closures run on the main thread. Tests replace every external side effect.
struct ActionSystem {
    var identity: (URL) -> FileIdentity? = FileIdentity.read
    var isAbsent: (URL) -> Bool = { url in
        var info = stat()
        return url.path.withCString { lstat($0, &info) } != 0 && errno == ENOENT
    }
    var open: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var launcher = LauncherSystem()
    // A configured script runs as the current user, without an extra TCC category
    // or sandbox. Hosts may deny capabilities; file access is checked separately.
    var permission: (ActionPermission) -> Bool = { _ in true }
    var readable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }
    var executable: (URL) -> Bool = { url in
        url.isFileURL && FileManager.default.isExecutableFile(atPath: url.path)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    var openWith: (URL, URL, @escaping (Bool) -> Void) -> Void = { file, app, completion in
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { running, error in
            DispatchQueue.main.async { completion(running != nil && error == nil) }
        }
    }
    var launch: (URL, @escaping (Bool) -> Void) -> Void = { url, completion in
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            DispatchQueue.main.async { completion(app != nil && error == nil) }
        }
    }
    var reveal: (URL) -> Bool = { NSWorkspace.shared.activateFileViewerSelecting([$0]); return true }
    var preview: (URL) -> Bool = { _ in false }
    var copy: (FileAction, URL, String) -> Bool = { action, url, name in
        let board = NSPasteboard.general
        board.clearContents()
        switch action {
        case .copyFile:
            return board.writeObjects([url as NSURL]) && board.string(forType: .fileURL) == url.absoluteString
        case .copyPath:
            return board.writeObjects([url as NSURL]) && board.setString(url.path, forType: .string)
                && board.string(forType: .string) == url.path && board.string(forType: .fileURL) == url.absoluteString
        case .copyName:
            return board.setString(name, forType: .string) && board.string(forType: .string) == name
        default: return false
        }
    }
    var recycle: (URL, @escaping (URL?, Error?) -> Void) -> Void = { url, completion in
        NSWorkspace.shared.recycle([url]) { mapping, error in
            DispatchQueue.main.async { completion(mapping[url], error) }
        }
    }
}

/// Validation always uses the request's target, never the current UI selection.
final class ActionExecutor {
    let session: SearchSession
    var system: ActionSystem
    var sources: () -> [SearchSource]
    var onEvent: ((ActionEvent) -> Void)?
    var onPaletteEvent: ((PaletteActionEvent) -> Void)?
    var dialog = DialogAdapter()
    var fileActions = FileActions()
    var commandRunner = CommandRunner()
    var runCommand: ((CommandInvocation, @escaping (CommandEvent) -> Void) -> Void)?
    var onCustomEvent: ((CustomActionEvent) -> Void)?
    private var trashing: Set<URL> = []
    private var mutationPermits: [UUID: FileMutationPermit] = [:]

    init(session: SearchSession, system: ActionSystem = ActionSystem(), sources: @escaping () -> [SearchSource]) {
        self.session = session; self.system = system; self.sources = sources
        session.onInvalidate = { [weak self] in
            self?.dialog.cancel()
            self?.mutationPermits.values.forEach { $0.cancel() }
        }
    }
    func capture(_ action: FileAction, paletteItem: PaletteItem) -> PaletteActionRequest? {
        guard paletteItem.actions.contains(action) else { return nil }
        let identity: FileIdentity?
        switch paletteItem {
        case .file: return nil
        case .application(let app): identity = action.requiresOnline ? system.identity(app.url) : nil
        case .web: identity = nil
        }
        return PaletteActionRequest(actionID: UUID(), token: session.token, action: action, item: paletteItem, identity: identity)
    }
    func validate(_ request: PaletteActionRequest) -> ActionFailure? {
        guard session.isCurrent(request.token) else { return .staleSession }
        guard session.context.mode == .ordinary || session.context.mode == .application else { return .contextUnavailable }
        guard request.item.actions.contains(request.action) else { return .unsupportedAction }
        switch request.item {
        case .file: return .unsupportedAction
        case .web(let web):
            guard request.action == .open, web.keyword.enabled, web.keyword.searchURL(web.text) == web.url else { return .invalidURL }
        case .application(let app):
            if request.action.requiresOnline {
                guard app.available, system.launcher.isApplication(app.url),
                      app.bundleIdentifier == nil || system.launcher.bundleIdentifier(app.url) == app.bundleIdentifier,
                      let identity = request.identity, let current = system.identity(app.url) else { return .applicationUnavailable }
                guard identity == current else { return .targetChanged }
            }
        }
        return nil
    }
    /// Nil means the workspace response is pending; acceptance is emitted later.
    @discardableResult
    func execute(_ request: PaletteActionRequest) -> ActionOutcome? {
        guard request.receipt.consume() else { return .cancelled(.alreadyDispatched) }
        if let failure = validate(request) { return emit(request, .cancelled(failure)) }
        switch request.item {
        case .web(let web): return emit(request, system.open(web.url) ? .accepted : .failed(.systemRejected))
        case .application(let app):
            switch request.action {
            case .open:
                var completed = false
                system.launch(app.url) { [self] accepted in
                    guard !completed else { return }; completed = true
                    emit(request, accepted ? .accepted : .failed(.systemRejected))
                }
                // The event is emitted only after the workspace response.
                return nil
            case .reveal: return emit(request, system.reveal(app.url) ? .accepted : .failed(.systemRejected))
            case .copyFile, .copyPath, .copyName:
                return emit(request, system.copy(request.action, app.url, app.name) ? .verified : .failed(.clipboardRejected))
            default: return emit(request, .failed(.unsupportedAction))
            }
        case .file: return emit(request, .failed(.unsupportedAction))
        }
    }
    @discardableResult
    private func emit(_ request: PaletteActionRequest, _ outcome: ActionOutcome) -> ActionOutcome {
        onPaletteEvent?(PaletteActionEvent(request: request, outcome: outcome)); return outcome
    }
    func capture(_ action: FileAction, item: ResultItem) -> ActionRequest? {
        let store = item.source.store
        let version = store.read { () -> UInt64? in
            guard Int(item.id) < store.count, store.isLive(item.id), store.path(item.id) == item.path else { return nil }
            return store.version
        }
        guard let version else { return nil }
        let url = URL(fileURLWithPath: item.path)
        // Offline metadata copies must not perform filesystem I/O.
        let current = sources().first { $0.id == item.source.id }
        let identity = action.requiresOnline && item.source.isOnline && current?.isOnline == true && current?.store === store
            ? system.identity(url) : nil
        return ActionRequest(actionID: UUID(), token: session.token, action: action,
                             target: FileTargetSnapshot(sourceID: item.source.id, sourceName: item.source.displayName,
                                                        wasOnline: item.source.isOnline, store: store, storeVersion: version,
                                                        entryID: item.id, url: url, name: item.name, identity: identity, isDirectory: item.kind == 1),
                             context: session.context)
    }
    func validate(_ request: ActionRequest) -> ActionFailure? {
        guard session.isCurrent(request.token) else { return .staleSession }
        if request.action == .contextNavigation && request.context.mode != .open && request.context.mode != .save { return .contextUnavailable }
        let target = request.target
        guard let source = sources().first(where: { $0.id == target.sourceID }) else { return .sourceUnavailable }
        guard source.store === target.store else { return .storeReplaced }
        if request.action.requiresOnline && (!target.wasOnline || !source.isOnline) { return .sourceUnavailable }
        let valid = target.store.read {
            Int(target.entryID) < target.store.count && target.store.isLive(target.entryID)
                && target.store.path(target.entryID) == target.url.path
        }
        guard valid else { return .targetChanged }
        if request.action.requiresOnline {
            guard let captured = target.identity, let current = system.identity(target.url) else { return .fileUnavailable }
            guard captured == current else { return .targetChanged }
        }
        return nil
    }
    @discardableResult
    func cancel(_ request: ActionRequest, reason: ActionFailure) -> ActionOutcome {
        guard request.receipt.consume() else { return .cancelled(.alreadyDispatched) }
        return emit(request, .cancelled(reason))
    }
    @discardableResult
    func execute(_ request: ActionRequest) -> ActionOutcome {
        guard request.receipt.consume() else { return .cancelled(.alreadyDispatched) }
        if let failure = validate(request) { return emit(request, .cancelled(failure)) }
        let target = request.target
        if request.action == .contextNavigation || (request.action == .open && (request.context.mode == .open || request.context.mode == .save)) {
            if let dialogContext = request.context.dialog, let original = dialogContext.target {
                guard let host = request.context.target, host.processID == original.hostPID,
                      host.windowIdentity == original.windowIdentity,
                      host.bundleIdentifier == dialogContext.capability?.bundleIdentifier else { return emit(request, .cancelled(.targetChanged)) }
            }
            let directory = target.isDirectory ? target.url : target.url.deletingLastPathComponent()
            let file = request.context.mode == .open && !target.isDirectory ? target.url : nil
            let outcome = dialog.navigate(directory: directory, file: file, context: request.context.dialog,
                                          token: request.token, host: request.context.target,
                                          validateOriginalFile: { FileIdentity.read(target.url) == target.identity ? nil : .invalidControl },
                                          isCurrent: { [weak self] in self?.session.isCurrent(request.token) == true }) { [weak self] outcome in
                guard let self, self.session.isCurrent(request.token) else { return }
                self.emit(request, outcome)
            }
            return emit(request, outcome)
        }
        switch request.action {
        case .open: return emit(request, system.open(target.url) ? .accepted : .failed(.systemRejected))
        case .reveal: return emit(request, system.reveal(target.url) ? .accepted : .failed(.systemRejected))
        case .preview: return emit(request, system.preview(target.url) ? .accepted : .failed(.systemRejected))
        case .copyFile, .copyPath, .copyName:
            return emit(request, system.copy(request.action, target.url, target.name) ? .verified : .failed(.clipboardRejected))
        case .trash:
            guard trashing.insert(target.url).inserted else { return emit(request, .cancelled(.alreadyDispatched)) }
            emit(request, .accepted)
            var completed = false
            system.recycle(target.url) { [self] destination, error in
                guard !completed else { return }; completed = true; trashing.remove(target.url)
                // A dispatched operation has a real result even if its session ended.
                if error != nil { emit(request, .failed(.systemRejected)); return }
                guard let destination, system.isAbsent(target.url),
                      let moved = system.identity(destination), moved.link == target.identity?.link else {
                    emit(request, .failed(.trashNotVerified)); return
                }
                emit(request, .verified)
            }
            return .accepted
        case .contextNavigation: return emit(request, .failed(.contextUnavailable))
        case .custom, .rename, .createDirectory: return emit(request, .failed(.unsupportedAction))
        }
    }
    func captureCustom(_ definition: ActionDefinition, file: ActionRequest) -> CustomActionRequest? {
        guard file.action == .custom else { return nil }
        let binding = ActionBinding(type: .file, url: file.target.url, name: file.target.name,
                                    directory: file.target.isDirectory ? file.target.url : file.target.url.deletingLastPathComponent())
        return CustomActionRequest(definition: definition, file: file, palette: nil, binding: binding, mode: file.context.mode)
    }
    func captureCustom(_ definition: ActionDefinition, item: PaletteItem) -> CustomActionRequest? {
        guard let palette = capture(.open, paletteItem: item) else { return nil }
        let binding: ActionBinding
        switch item {
        case .file: return nil
        case .application(let app): binding = ActionBinding(type: .application, url: app.url, name: app.name, directory: app.url.deletingLastPathComponent())
        case .web(let web): binding = ActionBinding(type: .web, url: web.url, name: web.text, directory: nil)
        }
        return CustomActionRequest(definition: definition, file: nil, palette: palette, binding: binding, mode: session.context.mode)
    }
    func validate(_ request: CustomActionRequest) -> ActionFailure? {
        if let file = request.file, let failure = validate(file) { return failure }
        if let palette = request.palette, let failure = validate(palette) { return failure }
        if request.definition.permissions.contains(.fileRead), request.binding.url.isFileURL,
           !system.readable(request.binding.url) { return .permissionDenied }
        return request.definition.unavailableReason(binding: request.binding, mode: request.mode,
            permission: system.permission, application: system.launcher.isApplication, executable: system.executable)
    }
    func execute(_ request: CustomActionRequest) {
        let consumed = request.file?.receipt.consume() ?? request.palette?.receipt.consume() ?? false
        guard consumed else { return }
        func report(_ outcome: ActionOutcome) { onCustomEvent?(CustomActionEvent(request: request, outcome: outcome)) }
        if let failure = validate(request) { report(.cancelled(failure)); return }
        switch request.definition.execution {
        case .application(let app):
            var completed = false
            system.openWith(request.binding.url, app) { [self] accepted in
                guard !completed else { return }; completed = true
                onCustomEvent?(CustomActionEvent(request: request, outcome: accepted ? .accepted : .failed(.systemRejected)))
            }
        case .urlTemplate:
            guard let url = try? request.definition.boundURL(request.binding) else { report(.failed(.invalidURL)); return }
            report(system.open(url) ? .accepted : .failed(.systemRejected))
        case .command:
            guard let invocation = try? CommandInvocation(definition: request.definition, binding: request.binding) else {
                report(.failed(.unsupportedAction)); return
            }
            var started = false, finished = false
            let callback: (CommandEvent) -> Void = { [self] event in
                guard !finished else { return }
                switch event {
                case .started:
                    guard !started else { return }; started = true
                    onCustomEvent?(CustomActionEvent(request: request, outcome: .accepted))
                case .cancelled(let failure):
                    finished = true
                    onCustomEvent?(CustomActionEvent(request: request, outcome: .cancelled(failure)))
                case .finished(let result):
                    finished = true
                    onCustomEvent?(CustomActionEvent(request: request, outcome: result.outcome))
                }
            }
            if let runCommand { runCommand(invocation, callback) } else { commandRunner.run(invocation, authorize: { [self] in validate(request) }, event: callback) }
        case .terminal: report(.failed(.terminalUnsupported))
        }
    }
    func execute(_ mutation: FileMutation, name: String) {
        let request = mutation.request
        guard request.receipt.consume() else { return }
        if let failure = validate(request) { emit(request, .cancelled(failure)); return }
        if let failure = FileActions.availability(mutation) { emit(request, .failed(failure)); return }
        // Main-thread source/session validation immediately precedes queue dispatch.
        // The worker receives immutable snapshots and rechecks disk identity.
        let permit = FileMutationPermit()
        mutationPermits[request.actionID] = permit
        fileActions.perform(mutation, name: name, authorize: { [self] in validate(request) }, begin: { permit.begin() }) { [self] outcome in
            mutationPermits.removeValue(forKey: request.actionID)
            emit(request, outcome)
        }
    }
    @discardableResult
    private func emit(_ request: ActionRequest, _ outcome: ActionOutcome) -> ActionOutcome {
        onEvent?(ActionEvent(request: request, outcome: outcome)); return outcome
    }
}

struct CustomActionRequest {
    let definition: ActionDefinition
    let file: ActionRequest?
    let palette: PaletteActionRequest?
    let binding: ActionBinding
    let mode: SearchMode
    var token: SearchSessionToken { file?.token ?? palette!.token }
    var actionID: UUID { file?.actionID ?? palette!.actionID }
}
struct CustomActionEvent {
    let request: CustomActionRequest
    let outcome: ActionOutcome
}
