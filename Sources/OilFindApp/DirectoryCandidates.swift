import Foundation
import OilFindCore

struct DirectoryCandidate: Identifiable {
    enum Origin: String { case finder, favorite }
    let id: String
    let name: String
    let url: URL
    let origin: Origin
    let sourceName: String
    let availability: DirectoryAvailability
    let finderDirectory: FinderDirectory?
}

enum DirectoryCandidates {
    /// No filesystem calls occur while inspecting index coverage.
    static func make(finder: FinderDirectory?, favorites: FavoritesStore, sources: [SearchSource]) -> [DirectoryCandidate] {
        var candidates: [DirectoryCandidate] = []
        func coverage(_ url: URL, availability: DirectoryAvailability, sourceID: String?) -> (DirectoryAvailability, String) {
            if let sourceID, let source = sources.first(where: { $0.id == sourceID }), !source.isOnline { return (.offline, source.displayName) }
            guard availability == .available else { return (availability, "") }
            let source = sources.first { source in
                source.isOnline && Searcher.directoryScopeIsAvailable(DirectoryScope(path: url.path), in: source.store)
            }
            return (source == nil ? .unindexed : .available, source?.displayName ?? "")
        }
        if let finder {
            let state = coverage(finder.directoryURL, availability: favorites.system.check(finder.directoryURL), sourceID: nil)
            candidates.append(DirectoryCandidate(id: "finder:" + finder.windowIdentity.uuidString, name: finder.directoryURL.lastPathComponent, url: finder.directoryURL, origin: .finder, sourceName: state.1, availability: state.0, finderDirectory: finder))
        }
        for entry in favorites.favorites {
            let resolved = favorites.resolve(entry), state = coverage(resolved.0, availability: resolved.1, sourceID: entry.sourceID)
            candidates.append(DirectoryCandidate(id: entry.id.uuidString, name: entry.name, url: resolved.0, origin: .favorite, sourceName: state.1, availability: state.0, finderDirectory: nil))
        }
        return candidates
    }
}
