import AppKit

/// An entry requires measured OS/app/profile compatibility, not just AX trust.
struct DialogCapability: Equatable {
    let bundleIdentifier: String
    let applicationVersion: String
    let systemVersion: String
    let profileID: String
    let mode: DialogMode
    let selectsFiles: Bool
}

struct DialogContext {
    let mode: DialogMode
    let target: DialogTarget?
    let capability: DialogCapability?
}

enum DialogWorkflowStatus: Equatable {
    case manual, navigating, navigated, directoryReady
    case failed(DialogFailure)
    var localizationKey: String {
        switch self {
        case .manual: return "dialog.manual"
        case .navigating: return "dialog.navigating"
        case .navigated: return "dialog.navigated"
        case .directoryReady: return "dialog.directoryReady"
        case .failed(let reason): return "dialog.failure." + reason.rawValue
        }
    }
}

/// Production approvals are empty until 002 supplies actual compatibility evidence.
/// The experimental, manually assisted AX client is never constructed here.
final class DialogAdapter {
    let permissions: AccessibilityPermissionChecking
    let capabilities: [DialogCapability]
    var enabled: () -> Bool
    var makeNavigator: ((DialogContext) -> DialogNavigation?)?
    var environmentMatches: (DialogCapability, DialogTarget) -> Bool = { capability, target in
        guard let app = NSRunningApplication(processIdentifier: target.hostPID), !app.isTerminated,
              app.bundleIdentifier == capability.bundleIdentifier, let url = app.bundleURL,
              Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == capability.applicationVersion,
              ProcessInfo.processInfo.operatingSystemVersionString == capability.systemVersion,
              !capability.profileID.isEmpty else { return false }
        return true
    }
    var onUpdate: (() -> Void)?
    private(set) var status: DialogWorkflowStatus = .manual
    private(set) var path: URL?
    private(set) var fileToSelect: URL?
    private(set) var token: SearchSessionToken?
    private var operation = UUID()
    private var navigator: DialogNavigation?
    var isNavigating: Bool { navigator != nil }

    init(permissions: AccessibilityPermissionChecking = SystemAccessibilityPermission(),
         capabilities: [DialogCapability] = [],
         enabled: @escaping () -> Bool = { UserDefaults.standard.bool(forKey: "dialogWorkflowsEnabled") }) {
        self.permissions = permissions; self.capabilities = capabilities; self.enabled = enabled
    }

    func cancel() {
        operation = UUID()
        let active = navigator; navigator = nil
        active?.cancel()
        if active != nil { status = .failed(.cancelled); onUpdate?() }
    }
    func reset() { cancel(); path = nil; fileToSelect = nil; token = nil; status = .manual; onUpdate?() }

    @discardableResult
    func navigate(directory: URL, file: URL?, context: DialogContext?, token: SearchSessionToken,
                  host: SearchContextTarget? = nil,
                  validateOriginalFile: @escaping () -> DialogFailure? = { nil },
                  isCurrent: @escaping () -> Bool,
                  completion: @escaping (ActionOutcome) -> Void) -> ActionOutcome {
        cancel(); self.path = directory; self.fileToSelect = file; self.token = token
        guard isCurrent() else { return .cancelled(.staleSession) }
        guard let context, let target = context.target, let capability = context.capability,
              capabilities.contains(capability), target.mode == context.mode,
              capability.mode == context.mode, enabled() else {
            status = .manual; onUpdate?(); return .failed(.dialogManual)
        }
        guard let host, host.processID == target.hostPID, host.windowIdentity == target.windowIdentity,
              host.bundleIdentifier == capability.bundleIdentifier, environmentMatches(capability, target) else {
            status = .failed(.targetReplaced); onUpdate?(); return .failed(.dialogFailed)
        }
        guard permissions.isTrusted() else {
            status = .failed(.permissionDenied); onUpdate?(); return .failed(.dialogFailed)
        }
        guard let nav = makeNavigator?(context) else {
            status = .manual; onUpdate?(); return .failed(.dialogManual)
        }
        let id = UUID(); operation = id; navigator = nav
        status = .navigating; onUpdate?()
        // Filesystem checks run on the navigator's AX worker, outside index locks.
        var pathSnapshot: (FileIdentity, FileIdentity?)?
        nav.start(directory: directory, file: context.mode == .open && capability.selectsFiles ? file : nil,
                  mode: context.mode, target: target, validatePath: { [weak self] in
            guard let self, self.enabled() else { return .cancelled }
            if let reason = validateOriginalFile() { return reason }
            var folder = ObjCBool(false)
            guard directory.isFileURL, FileManager.default.fileExists(atPath: directory.path, isDirectory: &folder),
                  folder.boolValue, FileManager.default.isReadableFile(atPath: directory.path),
                  let directoryIdentity = FileIdentity.read(directory) else { return .invalidControl }
            let fileIdentity = file.flatMap(FileIdentity.read)
            if let file {
                guard fileIdentity != nil, FileManager.default.isReadableFile(atPath: file.path),
                      file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == directoryIdentity.resolvedPath else { return .invalidControl }
            }
            if let snapshot = pathSnapshot {
                guard snapshot.0 == directoryIdentity, snapshot.1 == fileIdentity else { return .invalidControl }
            } else { pathSnapshot = (directoryIdentity, fileIdentity) }
            return nil
        }) { [weak self] result in
            guard let self, self.operation == id, isCurrent() else { return }
            self.navigator = nil
            switch result.state {
            case .verified:
                self.status = file != nil && !result.fileSelection ? .directoryReady : .navigated
                self.onUpdate?(); completion(.verified)
            case .failed(let reason), .cancelled(let reason):
                self.status = .failed(reason); self.onUpdate?(); completion(.failed(.dialogFailed))
            default:
                self.status = .failed(.systemError); self.onUpdate?(); completion(.failed(.dialogFailed))
            }
        }
        return .accepted
    }
}
