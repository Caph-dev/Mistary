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
    var token: SearchSessionToken { SearchSessionToken(sessionID: sessionID, queryGeneration: queryGeneration, actionGeneration: actionGeneration) }

    func begin(source: PanelSource, context: SearchContext) {
        sessionID = UUID(); queryGeneration = 0; actionGeneration = 0
        invocationSource = source; self.context = context; directoryScope = nil; isActive = true
    }
    func setDirectoryScope(_ url: URL?) {
        directoryScope = url?.standardizedFileURL; queryChanged()
    }
    func queryChanged() { queryGeneration &+= 1; invalidateActions() }
    func invalidateActions() { actionGeneration &+= 1 }
    func end() { isActive = false; invalidateActions() }
    func isCurrent(_ token: SearchSessionToken) -> Bool { isActive && self.token == token }
    /// Future directory resolvers must submit against the context they captured.
    @discardableResult
    func submitContext(_ context: SearchContext, for token: SearchSessionToken) -> Bool {
        guard isCurrent(token) else { return false }
        self.context = context; queryChanged(); return true
    }
}
