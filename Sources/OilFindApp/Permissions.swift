import AppKit
import Darwin
import ApplicationServices

struct SystemAccessibilityPermission: AccessibilityPermissionChecking {
    func isTrusted() -> Bool { AXIsProcessTrusted() }
    @discardableResult func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// Automation is target-specific and is not implied by AX or Full Disk Access.
struct PermissionStatus {
    let fullDiskAccess: Bool
    let accessibility: Bool
    let automation: String
}

enum Permissions {
    static func status(accessibility: AccessibilityPermissionChecking = SystemAccessibilityPermission()) -> PermissionStatus {
        PermissionStatus(fullDiskAccess: hasFullDiskAccess(), accessibility: accessibility.isTrusted(), automation: SystemFinderProbe.automationPermission() == noErr ? "granted" : "notGranted")
    }
    static func hasFullDiskAccess() -> Bool {
        let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = Darwin.open(path, O_RDONLY)
        if descriptor >= 0 { Darwin.close(descriptor); return true }
        guard errno == ENOENT else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/Safari")) != nil
    }
    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
