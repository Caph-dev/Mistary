import AppKit

struct PanelScreen: Equatable {
    let identity: String
    let frame: NSRect
    let visibleFrame: NSRect

    static var current: [PanelScreen] {
        NSScreen.screens.map {
            PanelScreen(identity: String(describing: $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"),
                        frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
    }
}

/// Only this application's preferences domain owns panel placement.
final class PanelPreferences {
    static let shared = PanelPreferences(defaults: UserDefaults(suiteName: ProductIdentity.bundleIdentifier)!)
    static let changed = Notification.Name(ProductIdentity.bundleIdentifier + ".panelPreferencesChanged")
    private let defaults: UserDefaults?
    private var transientKeepOpen = false
    private var transientPlacement: Placement?
    private struct Placement: Codable {
        let x: Double, y: Double, width: Double, height: Double
        let screen: String
        var frame: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }
    init(defaults: UserDefaults? = nil) { self.defaults = defaults }
    var keepOpen: Bool {
        get { (defaults?.object(forKey: "panelKeepOpen") as? Bool) ?? transientKeepOpen }
        set {
            transientKeepOpen = newValue; defaults?.set(newValue, forKey: "panelKeepOpen")
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    func save(frame: NSRect, screens: [PanelScreen]) {
        guard Self.valid(frame), let screen = Self.screen(for: frame, screens: screens) else { return }
        let placement = Placement(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height, screen: screen.identity)
        transientPlacement = placement
        if let data = try? JSONEncoder().encode(placement) { defaults?.set(data, forKey: "panelPlacement") }
    }
    func restoredFrame(screens: [PanelScreen], mouse: NSPoint) -> NSRect? {
        let usable = screens.filter { Self.valid($0.visibleFrame) }
        guard !usable.isEmpty else { return nil }
        let placement = defaults.flatMap { $0.data(forKey: "panelPlacement") }.flatMap { try? JSONDecoder().decode(Placement.self, from: $0) } ?? transientPlacement
        if let placement, Self.valid(placement.frame) {
            let screen = usable.first { $0.identity == placement.screen }
                ?? Self.screen(for: placement.frame, screens: usable) ?? usable[0]
            return Self.clamp(placement.frame, to: screen.visibleFrame)
        }
        let screen = usable.first { $0.frame.contains(mouse) } ?? usable[0]
        return Self.clamp(NSRect(x: screen.visibleFrame.midX - 400, y: screen.visibleFrame.midY - 280, width: 800, height: 560), to: screen.visibleFrame)
    }
    static func clamp(_ frame: NSRect, to visible: NSRect) -> NSRect {
        let width = min(visible.width, max(480, frame.width))
        let height = min(visible.height, max(360, frame.height))
        return NSRect(x: min(max(frame.minX, visible.minX), visible.maxX - width),
                      y: min(max(frame.minY, visible.minY), visible.maxY - height), width: width, height: height)
    }
    private static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }
    private static func screen(for frame: NSRect, screens: [PanelScreen]) -> PanelScreen? {
        screens.filter { valid($0.visibleFrame) }.max {
            let a = $0.visibleFrame.intersection(frame), b = $1.visibleFrame.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }
    }
}
