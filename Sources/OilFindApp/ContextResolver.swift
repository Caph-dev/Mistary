import AppKit

protocol ContextResolving {
    func capture(source: PanelSource) -> SearchContext
}

/// Finder and AX window recognition remain unavailable until their own plans.
struct ContextResolver: ContextResolving {
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    func capture(source: PanelSource) -> SearchContext {
        guard source.capturesExternalContext, let app = frontmostApplication(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .ordinary }
        return SearchContext(mode: .ordinary,
                             target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: nil),
                             directoryScope: nil)
    }
}

extension PanelSource {
    var capturesExternalContext: Bool { self == .hotkey || self == .menu || self == .reopen }
}
