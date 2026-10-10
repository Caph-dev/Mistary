import AppKit
import ApplicationServices
import Carbon

struct FinderDirectory: Equatable {
    enum Method: String { case accessibility, automation, desktop }
    let windowIdentity: UUID
    let directoryURL: URL
    let observedAt: Date
    let method: Method
}

enum FinderUnavailable: String { case permission, automation, recents, search, uncertain, changed, exited }
enum FinderObservation {
    case directory(FinderDirectory)
    case unavailable(FinderUnavailable)
}
protocol FinderProbing {
    func observe(processID: Int32, at date: Date) -> FinderObservation
    func isStillValid(_ directory: FinderDirectory, processID: Int32) -> Bool
}
extension FinderProbing {
    func isStillValid(_ directory: FinderDirectory, processID: Int32) -> Bool { false }
}

/// Cache entries are observations, never substitutes for a failed current observation.
final class FinderContext {
    let probe: FinderProbing
    let clock: () -> Date
    private(set) var directories: [UUID: FinderDirectory] = [:]
    private var processID: Int32?
    init(probe: FinderProbing = SystemFinderProbe(), clock: @escaping () -> Date = Date.init) {
        self.probe = probe; self.clock = clock
    }
    func capture(processID: Int32) -> FinderObservation {
        if self.processID != processID { directories.removeAll(); self.processID = processID }
        let result = probe.observe(processID: processID, at: clock())
        switch result {
        case .directory(let directory):
            // Only the currently observed window is retained. No claim of all-window coverage.
            directories = [directory.windowIdentity: directory]
        case .unavailable: directories.removeAll()
        }
        return result
    }
    func recentDirectory() -> FinderDirectory? {
        guard let processID, let directory = directories.values.first,
              probe.isStillValid(directory, processID: processID) else { invalidate(); return nil }
        return directory
    }
    func invalidate() { directories.removeAll(); processID = nil }
}

enum FinderAXValue {
    case value(CFTypeRef)
    case absent
    case failed
}
struct FinderAXSystem {
    var read: (AXUIElement, String) -> FinderAXValue = { element, name in
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .success, let value { return .value(value) }
        if error == .attributeUnsupported || error == .noValue { return .absent }
        return .failed
    }
}

final class SystemFinderProbe: FinderProbing {
    enum SearchInspection { case inactive, active, incomplete }
    private let ax: FinderAXSystem
    init(ax: FinderAXSystem = FinderAXSystem()) { self.ax = ax }
    private var lastAXWindow: AXUIElement?
    private var lastAXIdentity = UUID()
    private var scriptWindowID: String?
    private var scriptIdentity = UUID()
    private var lastProcessID: Int32?

    static func automationPermission(request: Bool = false) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, request)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard case .value(let value) = ax.read(element, name) else { return nil }
        return value
    }
    func inspectSearch(_ window: AXUIElement) -> SearchInspection {
        var queue = [window], count = 0
        while !queue.isEmpty && count < 1000 {
            let element = queue.removeLast(); count += 1
            guard let role = attribute(element, kAXRoleAttribute) as? String else { return .incomplete }
            let subrole: String?
            switch ax.read(element, kAXSubroleAttribute) {
            case .value(let value): subrole = value as? String
            case .absent: subrole = nil
            case .failed: return .incomplete
            }
            if role == "AXSearchField" || subrole == "AXSearchField" {
                guard let value = attribute(element, kAXValueAttribute) as? String else { return .incomplete }
                if !value.isEmpty { return .active }
            }
            switch ax.read(element, kAXChildrenAttribute) {
            case .value(let value):
                guard let children = value as? [AXUIElement] else { return .incomplete }
                queue += children
            case .absent: break
            case .failed: return .incomplete
            }
        }
        return queue.isEmpty ? .inactive : .incomplete
    }
    func documentIsUnchanged(_ window: AXUIElement, application: AXUIElement, text: String) -> Bool {
        guard let focused = attribute(application, kAXFocusedWindowAttribute), CFEqual(focused, window),
              attribute(window, kAXDocumentAttribute) as? String == text,
              inspectSearch(window) == .inactive,
              attribute(window, kAXDocumentAttribute) as? String == text,
              let finalFocused = attribute(application, kAXFocusedWindowAttribute), CFEqual(finalFocused, window) else { return false }
        return true
    }
    func observe(processID: Int32, at date: Date) -> FinderObservation {
        guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated,
              app.bundleIdentifier == "com.apple.finder" else { return .unavailable(.exited) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return .unavailable(.changed) }
        if lastProcessID != processID {
            lastAXWindow = nil; scriptWindowID = nil; lastProcessID = processID
        }
        guard AXIsProcessTrusted() else { return .unavailable(.permission) }
        let application = AXUIElementCreateApplication(processID)
        var focused: AXUIElement?
        switch ax.read(application, kAXFocusedWindowAttribute) {
        case .value(let value):
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable(.uncertain) }
            focused = (value as! AXUIElement)
        case .absent: break
        case .failed: return .unavailable(.uncertain)
        }
        if let focused {
            switch inspectSearch(focused) {
            case .active: lastAXWindow = nil; return .unavailable(.search)
            case .incomplete: return .unavailable(.uncertain)
            case .inactive: break
            }
            if let text = attribute(focused, kAXDocumentAttribute) as? String {
                guard let url = URL(string: text), url.isFileURL else { return .unavailable(.uncertain) }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return .unavailable(.uncertain) }
                guard documentIsUnchanged(focused, application: application, text: text),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return .unavailable(.changed) }
                if lastAXWindow == nil || !CFEqual(lastAXWindow!, focused) { lastAXIdentity = UUID() }
                lastAXWindow = focused
                return .directory(FinderDirectory(windowIdentity: lastAXIdentity, directoryURL: url.standardizedFileURL, observedAt: date, method: .accessibility))
            }
        }
        // Read-only fallback. No directory strings are interpolated into script source.
        guard Self.automationPermission() == noErr else { return .unavailable(AXIsProcessTrusted() ? .automation : .permission) }
        let source = Self.scriptSource
        guard let script = NSAppleScript(source: source) else { return .unavailable(.uncertain) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let id = result.atIndex(1)?.stringValue,
              let path = result.atIndex(2)?.stringValue, let kind = result.atIndex(3)?.stringValue else { return .unavailable(.uncertain) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return .unavailable(.changed) }
        if let reason = FinderUnavailable(rawValue: kind) { return .unavailable(reason) }
        guard path.hasPrefix("/"), !id.isEmpty else { return .unavailable(.uncertain) }
        if kind == "desktop" {
            guard focused == nil, case .absent = ax.read(application, kAXFocusedWindowAttribute) else { return .unavailable(.changed) }
        } else {
            guard let focused, let current = attribute(application, kAXFocusedWindowAttribute), CFEqual(current, focused),
                  let capturedTitle = result.atIndex(4)?.stringValue,
                  attribute(focused, kAXTitleAttribute) as? String == capturedTitle,
                  result.atIndex(5)?.int32Value == 1,
                  let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
                  windows.filter({ attribute($0, kAXTitleAttribute) as? String == capturedTitle }).count == 1,
                  inspectSearch(focused) == .inactive,
                  let finalFocused = attribute(application, kAXFocusedWindowAttribute), CFEqual(finalFocused, focused) else { return .unavailable(.changed) }
            if lastAXWindow == nil || !CFEqual(lastAXWindow!, focused) { scriptWindowID = nil }
            lastAXWindow = focused
        }
        if scriptWindowID != id { scriptIdentity = UUID(); scriptWindowID = id }
        return .directory(FinderDirectory(windowIdentity: scriptIdentity, directoryURL: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL, observedAt: date, method: kind == "desktop" ? .desktop : .automation))
    }
    func isStillValid(_ directory: FinderDirectory, processID: Int32) -> Bool {
        guard lastProcessID == processID, let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated,
              app.bundleIdentifier == "com.apple.finder", AXIsProcessTrusted() else { return false }
        // Only a previously observed AX document can be verified without guessing a window.
        guard directory.method == .accessibility, directory.windowIdentity == lastAXIdentity,
              let window = lastAXWindow else { return false }
        let application = AXUIElementCreateApplication(processID)
        return windowStillMatchesDirectory(window, application: application, url: directory.directoryURL)
    }
    func windowStillMatchesDirectory(_ window: AXUIElement, application: AXUIElement, url: URL) -> Bool {
        guard let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
              windows.contains(where: { CFEqual($0, window) }),
              let document = attribute(window, kAXDocumentAttribute) as? String,
              let observedURL = URL(string: document), observedURL.isFileURL, observedURL.standardizedFileURL.path == url.path,
              inspectSearch(window) == .inactive,
              attribute(window, kAXDocumentAttribute) as? String == document,
              let finalWindows = attribute(application, kAXWindowsAttribute) as? [AXUIElement],
              finalWindows.contains(where: { CFEqual($0, window) }) else { return false }
        return true
    }
    static let scriptSource = """
        tell application "Finder"
            if (count of Finder windows) is 0 then
                return {"desktop", POSIX path of (desktop as alias), "desktop"}
            end if
            set capturedWindow to front Finder window
            set capturedID to id of capturedWindow
            set capturedName to name of capturedWindow
            if capturedName is "Recents" or capturedName is "最近使用" then return {"", "", "recents"}
            if capturedName starts with "Searching" or capturedName starts with "搜索" then return {"", "", "search"}
            set capturedFolder to target of capturedWindow
            if class of capturedFolder is not folder and class of capturedFolder is not disk then return {"", "", "uncertain"}
            if URL of capturedFolder does not start with "file://" then return {"", "", "uncertain"}
            set directoryPath to POSIX path of (capturedFolder as alias)
            if id of front Finder window is not capturedID then return {"", "", "changed"}
            if POSIX path of (target of capturedWindow as alias) is not directoryPath then return {"", "", "changed"}
            set matchingWindows to every Finder window whose name is capturedName
            return {capturedID as text, directoryPath, "automation", capturedName, count of matchingWindows}
        end tell
        """
}
