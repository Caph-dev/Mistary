import AppKit
import Darwin
import OilFindCore

/// Path copy preserves the existing URL + text format; file copy is URL-only.
enum FileAction: String, CaseIterable {
    case open, reveal, preview, copyFile, copyPath, copyName, trash, contextNavigation
    var requiresOnline: Bool { self != .copyPath && self != .copyName }
}

enum ActionFailure: String, Error {
    case staleSession, sourceUnavailable, storeReplaced, targetChanged, fileUnavailable
    case systemRejected, clipboardRejected, trashNotVerified, contextUnavailable, alreadyDispatched, superseded
    case applicationUnavailable, invalidURL, unsupportedAction
}

enum ActionOutcome: Equatable {
    /// Only trash has a subsequent terminal event. Workspace and Quick Look
    /// acceptance does not prove that an external application read the file.
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
    private var trashing: Set<URL> = []

    init(session: SearchSession, system: ActionSystem = ActionSystem(), sources: @escaping () -> [SearchSource]) {
        self.session = session; self.system = system; self.sources = sources
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
                                                        entryID: item.id, url: url, name: item.name, identity: identity))
    }
    func validate(_ request: ActionRequest) -> ActionFailure? {
        guard session.isCurrent(request.token) else { return .staleSession }
        guard request.action != .contextNavigation else { return .contextUnavailable }
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
        }
    }
    @discardableResult
    private func emit(_ request: ActionRequest, _ outcome: ActionOutcome) -> ActionOutcome {
        onEvent?(ActionEvent(request: request, outcome: outcome)); return outcome
    }
}
