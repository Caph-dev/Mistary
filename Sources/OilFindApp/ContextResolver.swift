import AppKit

protocol ContextResolving {
    func capture(source: PanelSource) -> SearchContext
    func capture(source: PanelSource, completion: @escaping (SearchContext) -> Void)
}
extension ContextResolving {
    func capture(source: PanelSource, completion: @escaping (SearchContext) -> Void) { completion(capture(source: source)) }
}

/// Captured before the panel takes focus; unknown contexts remain ordinary.
struct ContextResolver: ContextResolving {
    var finder = FinderContext()
    var frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var dialogRecognition = SystemDialogRecognition()
    var workflowsEnabled: () -> Bool = { UserDefaults.standard.bool(forKey: "dialogWorkflowsEnabled") }
    func capture(source: PanelSource) -> SearchContext {
        guard source.capturesExternalContext, let app = frontmostApplication(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return .ordinary }
        if app.bundleIdentifier == "com.apple.finder" {
            switch finder.capture(processID: app.processIdentifier) {
            case .directory(let directory):
                return SearchContext(mode: .finder, target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: directory.windowIdentity), directoryScope: directory.directoryURL, finderDirectory: directory, finderDirectoryIsCurrent: { finder.recentDirectory() == directory })
            case .unavailable(let reason):
                return SearchContext(mode: .ordinary, target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: nil), directoryScope: nil, finderUnavailable: reason)
            }
        }
        let recent = finder.recentDirectory()
        return SearchContext(mode: .ordinary,
                             target: SearchContextTarget(processID: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, windowIdentity: nil),
                             directoryScope: nil, recentFinderDirectory: recent, finderDirectoryIsCurrent: { recent != nil && finder.recentDirectory() == recent })
    }
    func capture(source: PanelSource, completion: @escaping (SearchContext) -> Void) {
        let base = capture(source: source)
        guard workflowsEnabled(), let target = base.target, base.mode == .ordinary,
              target.bundleIdentifier != "com.apple.finder" else { completion(base); return }
        dialogRecognition.capture(processID: target.processID) { mode in
            guard frontmostApplication()?.processIdentifier == target.processID else { completion(.ordinary); return }
            guard let mode else { completion(base); return }
            // Heuristics only establish a manual context, never an automation capability.
            let context = SearchContext(mode: mode == .open ? .open : .save, target: target,
                                    directoryScope: nil, recentFinderDirectory: base.recentFinderDirectory,
                                    dialog: DialogContext(mode: mode, target: nil, capability: nil),
                                    finderDirectoryIsCurrent: base.finderDirectoryIsCurrent)
            completion(context)
        }
    }
}

extension PanelSource {
    var capturesExternalContext: Bool { self == .hotkey || self == .menu || self == .reopen }
}
