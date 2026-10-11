import AppKit
import ApplicationServices
import CryptoKit
import Carbon

/// Tokens disclose neither document titles nor arbitrary identifier strings.
struct AXControlProfile {
    let panel: String
    let pathField: String
    let directoryBrowser: String
    let filenameField: String?
}

struct AXCapability {
    let token: String?
    let role: String
    let valueWritable: Bool
    let hasURL: Bool
    let actions: [String]
    let processID: Int32
    let depth: Int
}

/// A conservative, manually assisted adapter. The operator opens the path sheet
/// and confirms it; this client never presses a panel button or synthesizes keys.
final class SystemAccessibilityClient: DialogAccessibilityClient {
    private let hostPID: pid_t
    private let profile: AXControlProfile?
    private let mistaryPID: pid_t
    private let messagingTimeout: TimeInterval
    private var captured: Captured?
    private var hostLaunch: Date?
    private var handoffComplete = false

    private struct Captured {
        let target: DialogTarget
        let hostLaunch: Date
        let axLaunch: Date
        let application: AXUIElement
        let window: AXUIElement
        let panel: AXUIElement
        let pathSheet: AXUIElement
        let path: AXUIElement
        let browser: AXUIElement
        let filename: AXUIElement?
    }
    private struct Node {
        let element: AXUIElement
        let role: String
        let token: String?
        let depth: Int
    }

    init(hostPID: pid_t, profile: AXControlProfile? = nil,
         mistaryPID: pid_t = ProcessInfo.processInfo.processIdentifier, messagingTimeout: TimeInterval = 0.2) {
        self.hostPID = hostPID; self.profile = profile; self.mistaryPID = mistaryPID
        self.messagingTimeout = messagingTimeout
    }

    func inspect(context: DialogCallContext) throws -> [AXCapability] {
        guard hostPID != mistaryPID, let host = NSRunningApplication(processIdentifier: hostPID), !host.isTerminated,
              let launch = host.launchDate else {
            throw DialogFailure.targetExited
        }
        hostLaunch = launch
        guard frontmostPID == hostPID else { throw DialogFailure.unexpectedFocus }
        let app = AXUIElementCreateApplication(hostPID)
        let window = try element(app, kAXFocusedWindowAttribute, context)
        return try nodes(window, context).map { node in
            try context.check()
            var writable = DarwinBoolean(false)
            try request(node.element, context) {
                let error = AXUIElementIsAttributeSettable(node.element, kAXValueAttribute as CFString, &writable)
                if error != .attributeUnsupported && error != .noValue { try check(error) }
            }
            return AXCapability(token: node.token, role: node.role, valueWritable: writable.boolValue,
                                hasURL: try attributeNames(node.element, context).contains(kAXURLAttribute),
                                actions: try actions(node.element, context), processID: try pid(node.element, context), depth: node.depth)
        }
    }

    func capture(mode: DialogMode, generation: UUID, context: DialogCallContext) throws -> DialogTarget {
        guard let profile else { throw DialogFailure.unsupportedControl }
        guard hostPID != mistaryPID, let host = NSRunningApplication(processIdentifier: hostPID),
              !host.isTerminated, let hostLaunch = host.launchDate else { throw DialogFailure.targetExited }
        self.hostLaunch = hostLaunch
        handoffComplete = false
        guard frontmostPID == hostPID else { throw DialogFailure.unexpectedFocus }
        let app = AXUIElementCreateApplication(hostPID)
        let window = try element(app, kAXFocusedWindowAttribute, context)
        let all = try nodes(window, context)
        let panel = try unique(profile.panel, all)
        let panelSubrole = try string(panel.element, kAXSubroleAttribute, context)
        guard panel.role == kAXSheetRole || (panel.role == kAXWindowRole && panelSubrole == kAXDialogSubrole) else {
            throw DialogFailure.invalidControl
        }
        let descendants = try nodes(panel.element, context)
        let path = try unique(profile.pathField, descendants)
        let browser = try unique(profile.directoryBrowser, descendants)
        guard path.role == kAXTextFieldRole || path.role == kAXComboBoxRole,
              browser.role == kAXBrowserRole, !CFEqual(path.element, browser.element) else {
            throw DialogFailure.unsupportedDirectoryObservation
        }
        // A browser URL is accepted only if it names an existing directory. Its
        // interpretation still needs app-specific experimental evidence.
        guard let directory = try url(browser.element, context), isDirectory(directory) else {
            throw DialogFailure.unsupportedDirectoryObservation
        }
        let pathSheet = try element(path.element, kAXParentAttribute, context)
        let sheet = try enclosingSheet(pathSheet, stoppingAt: panel.element, context: context)
        guard !CFEqual(sheet, panel.element), try contains(sheet, in: panel.element, context) else {
            throw DialogFailure.invalidControl
        }
        var filename: AXUIElement?
        if mode == .save {
            guard let token = profile.filenameField else { throw DialogFailure.invalidControl }
            let node = try unique(token, descendants)
            guard node.role == kAXTextFieldRole, !CFEqual(node.element, path.element),
                  !(try contains(node.element, in: sheet, context)),
                  try string(node.element, kAXValueAttribute, context) != nil else { throw DialogFailure.invalidControl }
            filename = node.element
        }
        let axPID = try pid(panel.element, context)
        guard let ax = NSRunningApplication(processIdentifier: axPID), !ax.isTerminated,
              let axLaunch = ax.launchDate else { throw DialogFailure.targetExited }
        // The host's AX focused-window tree supplies the association with a
        // helper process. Unrelated frontmost helpers are never discovered.
        let target = DialogTarget(hostPID: hostPID, accessibilityPID: axPID,
                                  windowIdentity: UUID(), panelIdentity: UUID(), mode: mode, generation: generation)
        captured = Captured(target: target, hostLaunch: hostLaunch, axLaunch: axLaunch,
                            application: app, window: window, panel: panel.element,
                            pathSheet: sheet, path: path.element, browser: browser.element, filename: filename)
        try validate(target, allowMistaryFocus: true, context: context)
        return target
    }

    func validate(_ target: DialogTarget, allowMistaryFocus: Bool, context: DialogCallContext) throws {
        let c = try matching(target)
        guard let host = NSRunningApplication(processIdentifier: target.hostPID), !host.isTerminated,
              host.launchDate == c.hostLaunch,
              let ax = NSRunningApplication(processIdentifier: target.accessibilityPID), !ax.isTerminated,
              ax.launchDate == c.axLaunch else { throw DialogFailure.targetExited }
        guard try pid(c.panel, context) == target.accessibilityPID else { throw DialogFailure.targetReplaced }
        let windows = try elements(c.application, kAXWindowsAttribute, context)
        guard windows.contains(where: { CFEqual($0, c.window) }),
              CFEqual(c.window, try element(c.application, kAXFocusedWindowAttribute, context)),
              (try nodes(c.window, context)).contains(where: { CFEqual($0.element, c.panel) }) else { throw DialogFailure.targetReplaced }
        let current = frontmostPID
        if current == mistaryPID && allowMistaryFocus { return }
        guard current == target.hostPID || current == target.accessibilityPID else { throw DialogFailure.unexpectedFocus }
        let focused = try element(AXUIElementCreateApplication(current), kAXFocusedUIElementAttribute, context)
        guard try contains(focused, in: c.panel, context) else { throw DialogFailure.unexpectedFocus }
    }

    func handoff(_ target: DialogTarget, context: DialogCallContext) throws {
        let c = try matching(target)
        try validate(target, allowMistaryFocus: true, context: context)
        if frontmostPID == mistaryPID {
            try request(c.application, context) {
                try check(AXUIElementSetAttributeValue(c.application, kAXFrontmostAttribute as CFString, kCFBooleanTrue))
            }
        }
        try poll(context) {
            if self.frontmostPID == self.mistaryPID {
                try self.validate(target, allowMistaryFocus: true, context: context)
                return false
            }
            try self.validate(target, allowMistaryFocus: false, context: context)
            return true
        }
        handoffComplete = true
    }

    func preparePathControl(_ target: DialogTarget, context: DialogCallContext) throws {
        let c = try matching(target)
        guard try pid(c.panel, context) == target.accessibilityPID else { throw DialogFailure.targetReplaced }
        guard !IsSecureEventInputEnabled() else { throw DialogFailure.secureInput }
        guard (try nodes(c.panel, context)).contains(where: { CFEqual($0.element, c.pathSheet) }),
              (try nodes(c.pathSheet, context)).contains(where: { CFEqual($0.element, c.path) }),
              try string(c.path, kAXRoleAttribute, context) != kAXSecureTextFieldSubrole,
              (try string(c.path, kAXSubroleAttribute, context)) != kAXSecureTextFieldSubrole else {
            throw DialogFailure.invalidControl
        }
        let focused = try element(AXUIElementCreateApplication(frontmostPID), kAXFocusedUIElementAttribute, context)
        guard CFEqual(focused, c.path) else { throw DialogFailure.unexpectedFocus }
        var writable = DarwinBoolean(false)
        try request(c.path, context) { try check(AXUIElementIsAttributeSettable(c.path, kAXValueAttribute as CFString, &writable)) }
        guard writable.boolValue else { throw DialogFailure.unsupportedControl }
        guard try string(c.path, kAXValueAttribute, context) != nil else { throw DialogFailure.invalidControl }
    }

    func observe(_ target: DialogTarget, context: DialogCallContext) throws -> DialogObservation {
        let c = try matching(target)
        let directory = try url(c.browser, context)
        let filename = try c.filename.map { try string($0, kAXValueAttribute, context) } ?? nil
        return DialogObservation(directory: directory, filename: filename, selectedFile: nil)
    }

    func writeDirectory(_ url: URL, target: DialogTarget, context: DialogCallContext) throws {
        guard isDirectory(url) else { throw DialogFailure.invalidControl }
        let c = try matching(target)
        try validate(target, allowMistaryFocus: false, context: context)
        try preparePathControl(target, context: context)
        // There is an unavoidable validation-to-dispatch race. No keyboard or
        // default-button action is sent, even when cancellation follows this call.
        try request(c.path, context) {
            guard !IsSecureEventInputEnabled() else { throw DialogFailure.secureInput }
            let current = frontmostPID
            guard current == target.hostPID || current == target.accessibilityPID else { throw DialogFailure.unexpectedFocus }
            let focused = try element(AXUIElementCreateApplication(current), kAXFocusedUIElementAttribute, context)
            guard CFEqual(focused, c.path) else { throw DialogFailure.unexpectedFocus }
            guard frontmostPID == current else { throw DialogFailure.unexpectedFocus }
            try context.check()
            guard !IsSecureEventInputEnabled() else { throw DialogFailure.secureInput }
            try check(AXUIElementSetMessagingTimeout(c.path, Float(min(messagingTimeout, context.remaining))))
            try context.check()
            try check(AXUIElementSetAttributeValue(c.path, kAXValueAttribute as CFString, url.path as CFString))
        }
        guard try string(c.path, kAXValueAttribute, context) == url.path else { throw DialogFailure.invalidControl }
    }

    func confirmDirectory(_ target: DialogTarget, context: DialogCallContext) throws {
        let c = try matching(target)
        // The operator confirms Go to Folder. Observe its disappearance rather
        // than sending AXConfirm, whose semantics differ between applications.
        try poll(context) {
            try self.validate(target, allowMistaryFocus: false, context: context)
            return !(try self.nodes(c.panel, context)).contains { CFEqual($0.element, c.pathSheet) }
        }
    }

    func selectFile(_ url: URL, target: DialogTarget, context: DialogCallContext) throws {
        try context.check()
        throw DialogFailure.selectionUnsupported
    }

    private var frontmostPID: pid_t { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1 }

    private func matching(_ target: DialogTarget) throws -> Captured {
        guard let c = captured, c.target.generation == target.generation,
              c.target.hostPID == target.hostPID, c.target.accessibilityPID == target.accessibilityPID,
              c.target.windowIdentity == target.windowIdentity, c.target.panelIdentity == target.panelIdentity,
              c.target.mode == target.mode else { throw DialogFailure.targetReplaced }
        return c
    }

    private func request<T>(_ element: AXUIElement, _ context: DialogCallContext, _ body: () throws -> T) throws -> T {
        try context.check()
        guard AXIsProcessTrusted() else { throw DialogFailure.permissionRevoked }
        guard let host = NSRunningApplication(processIdentifier: hostPID), !host.isTerminated,
              host.launchDate == hostLaunch else { throw DialogFailure.targetExited }
        let current = frontmostPID
        guard current == hostPID || current == captured?.target.accessibilityPID ||
              (current == mistaryPID && !handoffComplete) else { throw DialogFailure.unexpectedFocus }
        try check(AXUIElementSetMessagingTimeout(element, Float(min(messagingTimeout, context.remaining))))
        try context.check()
        let result = try body()
        try context.check()
        return result
    }

    private func check(_ error: AXError) throws {
        switch error {
        case .success: return
        case .apiDisabled: throw DialogFailure.permissionRevoked
        case .invalidUIElement: throw DialogFailure.targetReplaced
        case .cannotComplete: throw DialogFailure.resultUnknown
        default: throw DialogFailure.systemError
        }
    }

    private func value(_ element: AXUIElement, _ name: String, _ context: DialogCallContext) throws -> CFTypeRef? {
        try request(element, context) {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            if error == .attributeUnsupported || error == .noValue { return nil }
            try check(error)
            return result
        }
    }
    private func string(_ element: AXUIElement, _ name: String, _ context: DialogCallContext) throws -> String? {
        try value(element, name, context) as? String
    }
    private func element(_ element: AXUIElement, _ name: String, _ context: DialogCallContext) throws -> AXUIElement {
        guard let value = try value(element, name, context), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw DialogFailure.targetReplaced
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private func elements(_ element: AXUIElement, _ name: String, _ context: DialogCallContext) throws -> [AXUIElement] {
        guard let result = try value(element, name, context) else { return [] }
        guard CFGetTypeID(result) == CFArrayGetTypeID(), let array = result as? [AnyObject],
              array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { throw DialogFailure.invalidControl }
        return array.map { unsafeBitCast($0, to: AXUIElement.self) }
    }
    private func url(_ element: AXUIElement, _ context: DialogCallContext) throws -> URL? {
        guard let value = try value(element, kAXURLAttribute, context), CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        let result = value as! URL
        return result.isFileURL ? result.standardizedFileURL : nil
    }
    private func pid(_ element: AXUIElement, _ context: DialogCallContext) throws -> pid_t {
        try request(element, context) {
            var result: pid_t = 0
            try check(AXUIElementGetPid(element, &result))
            return result
        }
    }
    private func attributeNames(_ element: AXUIElement, _ context: DialogCallContext) throws -> [String] {
        try request(element, context) {
            var result: CFArray?
            try check(AXUIElementCopyAttributeNames(element, &result))
            return result as? [String] ?? []
        }
    }
    private func actions(_ element: AXUIElement, _ context: DialogCallContext) throws -> [String] {
        try request(element, context) {
            var result: CFArray?
            let error = AXUIElementCopyActionNames(element, &result)
            if error == .notImplemented { return [] }
            try check(error)
            // Only standard action names are safe to report.
            let safe = Set([kAXPressAction, kAXConfirmAction, kAXRaiseAction, kAXCancelAction])
            return (result as? [String] ?? []).filter { safe.contains($0) }
        }
    }

    private func nodes(_ root: AXUIElement, _ context: DialogCallContext) throws -> [Node] {
        var pending: [(AXUIElement, Int)] = [(root, 0)], result: [Node] = []
        while !pending.isEmpty {
            try context.check()
            let (element, depth) = pending.removeFirst()
            if result.contains(where: { CFEqual($0.element, element) }) { continue }
            guard result.count < 128, depth <= 10 else { throw DialogFailure.unsupportedControl }
            let role = try string(element, kAXRoleAttribute, context) ?? "unknown"
            let identifier = try string(element, kAXIdentifierAttribute, context)
            let token = identifier.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
            result.append(Node(element: element, role: role, token: token, depth: depth))
            let children = try elements(element, kAXChildrenAttribute, context)
            pending.append(contentsOf: children.map { ($0, depth + 1) })
        }
        return result
    }
    private func unique(_ token: String, _ nodes: [Node]) throws -> Node {
        let matches = nodes.filter { $0.token == token }
        guard matches.count == 1 else { throw DialogFailure.invalidControl }
        return matches[0]
    }
    private func contains(_ descendant: AXUIElement, in ancestor: AXUIElement, _ context: DialogCallContext) throws -> Bool {
        var current = descendant
        for _ in 0..<12 {
            if CFEqual(current, ancestor) { return true }
            guard let parent = try value(current, kAXParentAttribute, context), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = unsafeBitCast(parent, to: AXUIElement.self)
        }
        return false
    }
    private func enclosingSheet(_ start: AXUIElement, stoppingAt panel: AXUIElement, context: DialogCallContext) throws -> AXUIElement {
        var current = start
        for _ in 0..<12 {
            if CFEqual(current, panel) { throw DialogFailure.invalidControl }
            if try string(current, kAXRoleAttribute, context) == kAXSheetRole { return current }
            current = try element(current, kAXParentAttribute, context)
        }
        throw DialogFailure.invalidControl
    }
    private func poll(_ context: DialogCallContext, _ predicate: () throws -> Bool) throws {
        while true {
            try context.check()
            if try predicate() { return }
            Thread.sleep(forTimeInterval: min(0.025, context.remaining))
        }
    }
    private func isDirectory(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

/// Read-only, opt-in recognition. Button labels are hints for manual mode only.
/// A total deadline and traversal limits bound each queued observation.
final class SystemDialogRecognition {
    private let queue = DispatchQueue(label: "me.caph.mistary.dialog-recognition", qos: .userInitiated)
    private let trusted: () -> Bool
    private let frontmostPID: () -> Int32?
    private let readAttribute: (AXUIElement, String, DialogCallContext) throws -> CFTypeRef?
    init(trusted: @escaping () -> Bool = { AXIsProcessTrusted() },
         frontmostPID: @escaping () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         readAttribute: @escaping (AXUIElement, String, DialogCallContext) throws -> CFTypeRef? = { element, name, context in
             guard AXUIElementSetMessagingTimeout(element, Float(min(0.08, context.remaining))) == .success else { throw DialogFailure.systemError }
             var value: CFTypeRef?
             let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
             if error == .attributeUnsupported || error == .noValue { return nil }
             guard error == .success else { throw DialogFailure.systemError }
             return value
         }) {
        self.trusted = trusted; self.frontmostPID = frontmostPID; self.readAttribute = readAttribute
    }
    func capture(processID: Int32, completion: @escaping (DialogMode?) -> Void) {
        guard trusted() else { completion(nil); return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        // Delivery and the watchdog share the main queue; late IPC cannot deliver twice.
        var delivered = false
        func deliver(_ mode: DialogMode?) {
            guard !delivered else { return }; delivered = true; completion(mode)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { deliver(nil) }
        queue.async {
            let context = DialogCallContext(deadline: deadline, now: { ProcessInfo.processInfo.systemUptime }) {
                self.trusted() ? nil : .permissionRevoked
            }
            let mode = try? self.inspect(processID: processID, context: context)
            DispatchQueue.main.async { deliver(mode ?? nil) }
        }
    }
    private func inspect(processID: Int32, context: DialogCallContext) throws -> DialogMode? {
        func read(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
            try context.check()
            guard frontmostPID() == processID else { throw DialogFailure.unexpectedFocus }
            let value = try readAttribute(element, name, context)
            try context.check()
            return value
        }
        let app = AXUIElementCreateApplication(processID)
        guard let value = try read(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeBitCast(value, to: AXUIElement.self)
        struct Evidence { var browser = false; var modes = Set<String>() }
        var nodes: [(AXUIElement, Int, Int?)] = [(window, 0, nil)]
        var visited = 0, containers: [Int: Evidence] = [:]
        while let (element, depth, parentContainer) = nodes.popLast() {
            visited += 1
            guard visited <= 120, depth <= 10 else { return nil }
            let role = try read(element, kAXRoleAttribute) as? String
            let subrole = try read(element, kAXSubroleAttribute) as? String
            let startsContainer = role == kAXSheetRole || subrole == kAXDialogSubrole
            let container: Int? = startsContainer ? visited : parentContainer
            if startsContainer { containers[visited] = Evidence() }
            if let container {
                if role == kAXBrowserRole { containers[container]?.browser = true }
                if role == kAXButtonRole, let title = try read(element, kAXTitleAttribute) as? String {
                    if ["Open", "打开", "開啟"].contains(title) { containers[container]?.modes.insert(DialogMode.open.rawValue) }
                    if ["Save", "存储", "保存", "儲存"].contains(title) { containers[container]?.modes.insert(DialogMode.save.rawValue) }
                }
            }
            if let children = try read(element, kAXChildrenAttribute) as? [AXUIElement] {
                guard nodes.count + children.count + visited <= 120 else { return nil }
                nodes.append(contentsOf: children.map { ($0, depth + 1, container) })
            }
        }
        // Bind the result to the same focused window after traversal.
        let matches = containers.values.filter { $0.browser && $0.modes.count == 1 }
        guard matches.count == 1, let name = matches.first?.modes.first,
              let current = try read(app, kAXFocusedWindowAttribute), CFEqual(current, window) else { return nil }
        return DialogMode(rawValue: name)
    }
}
