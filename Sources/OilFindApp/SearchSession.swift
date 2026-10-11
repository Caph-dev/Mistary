import Foundation

/// These modes describe captured context, not permission to navigate another app.
enum SearchMode: String { case ordinary, application, finder, open, save }

struct SearchContextTarget: Equatable {
    let processID: Int32
    let bundleIdentifier: String?
    let windowIdentity: UUID?
}

struct SearchContext {
    let mode: SearchMode
    let target: SearchContextTarget?
    let directoryScope: URL?
    var finderDirectory: FinderDirectory? = nil
    var finderUnavailable: FinderUnavailable? = nil
    var recentFinderDirectory: FinderDirectory? = nil
    var dialog: DialogContext? = nil
    var finderDirectoryIsCurrent: (() -> Bool)? = nil
    static let ordinary = SearchContext(mode: .ordinary, target: nil, directoryScope: nil)
}

struct SearchSessionToken: Equatable {
    let sessionID: UUID
    let queryGeneration: UInt64
    let actionGeneration: UInt64
}

/// Owned by the main thread, alongside the panel and action executor.
final class SearchSession {
    private(set) var sessionID = UUID()
    private(set) var queryGeneration: UInt64 = 0
    private(set) var actionGeneration: UInt64 = 0
    private(set) var invocationSource: PanelSource = .indexing
    private(set) var context = SearchContext.ordinary
    private(set) var isActive = true
    private(set) var directoryScope: URL? = nil
    private(set) var contextAvailable = true
    var contextLifetime: TimeInterval?
    private var capturedAt: Date
    private let now: () -> Date
    var onContextUnavailable: (() -> Void)?
    init(now: @escaping () -> Date = Date.init) { self.now = now; capturedAt = now() }
    var onInvalidate: (() -> Void)?
    var token: SearchSessionToken { SearchSessionToken(sessionID: sessionID, queryGeneration: queryGeneration, actionGeneration: actionGeneration) }

    func begin(source: PanelSource, context: SearchContext) {
        onInvalidate?()
        sessionID = UUID(); queryGeneration = 0; actionGeneration = 0
        invocationSource = source; self.context = context; directoryScope = nil; isActive = true
        contextAvailable = true; capturedAt = now()
    }
    func setDirectoryScope(_ url: URL?) {
        directoryScope = url?.standardizedFileURL; queryChanged()
    }
    func setMode(_ mode: SearchMode) {
        context = SearchContext(mode: mode, target: context.target, directoryScope: context.directoryScope,
                                finderDirectory: context.finderDirectory, finderUnavailable: context.finderUnavailable,
                                recentFinderDirectory: context.recentFinderDirectory,
                                dialog: context.dialog.flatMap { ($0.mode == .open && mode == .open) || ($0.mode == .save && mode == .save) ? $0 : nil },
                                finderDirectoryIsCurrent: context.finderDirectoryIsCurrent)
        queryChanged()
    }
    func queryChanged() { queryGeneration &+= 1; invalidateActions() }
    func invalidateActions() { actionGeneration &+= 1; onInvalidate?() }
    func end() { isActive = false; invalidateActions() }
    func isCurrent(_ token: SearchSessionToken) -> Bool {
        validateContext()
        return isActive && self.token == token && (contextAvailable || (context.mode != .open && context.mode != .save))
    }
    func validateContext() {
        guard isActive, let lifetime = contextLifetime, now().timeIntervalSince(capturedAt) >= lifetime else { return }
        invalidateContext()
    }
    func invalidateContext() {
        guard isActive, contextAvailable, context.mode == .open || context.mode == .save else { return }
        contextAvailable = false
        // Drop all captured dialog authority without binding to a different foreground app.
        context = SearchContext(mode: context.mode, target: nil, directoryScope: nil,
                                recentFinderDirectory: context.recentFinderDirectory)
        invalidateActions(); onContextUnavailable?()
    }
    /// Future directory resolvers must submit against the context they captured.
    @discardableResult
    func submitContext(_ context: SearchContext, for token: SearchSessionToken) -> Bool {
        guard isCurrent(token) else { return false }
        self.context = context; queryChanged(); return true
    }
}
