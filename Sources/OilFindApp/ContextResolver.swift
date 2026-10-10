import AppKit

protocol ContextResolving {
    func capture(source: PanelSource) -> SearchContext
}

/// Captured before the panel takes focus; unknown contexts remain ordinary.
struct ContextResolver: ContextResolving {
    var finder = FinderContext()
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    func capture(source: PanelSource) -> SearchContext {
        guard source.capturesExternalContext, let app = frontmostApplication(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .ordinary }
        if app.bundleIdentifier == "com.apple.finder" {
            switch finder.capture(processID: app.processIdentifier) {
            case .directory(let directory):
                return SearchContext(mode: .finder, target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: directory.windowIdentity), directoryScope: directory.directoryURL, finderDirectory: directory)
            case .unavailable(let reason):
                return SearchContext(mode: .ordinary, target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: nil), directoryScope: nil, finderUnavailable: reason)
            }
        }
        return SearchContext(mode: .ordinary,
                             target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: nil),
                             directoryScope: nil, recentFinderDirectory: finder.recentDirectory())
    }
}

extension PanelSource {
    var capturesExternalContext: Bool { self == .hotkey || self == .menu || self == .reopen }
}
