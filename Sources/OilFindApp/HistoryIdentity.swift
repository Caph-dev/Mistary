import Foundation
import Darwin

/// Persistent identity never contains an index entry ID. Resolve outside index locks.
struct HistoryIdentity: Codable, Equatable {
    let sourceID: String
    let path: String
    let bookmark: Data?
    let volume: String?
    let file: FileIdentity

    private static func sameNode(_ a: FileIdentity.Node, _ b: FileIdentity.Node) -> Bool {
        a.inode == b.inode && a.birthSeconds == b.birthSeconds && a.birthNanoseconds == b.birthNanoseconds
    }
    func sameObject(as other: HistoryIdentity) -> Bool {
        guard sourceID == other.sourceID, volume == other.volume else { return false }
        if volume == nil && file.link.device != other.file.link.device { return false }
        return Self.sameNode(file.link, other.file.link) && Self.sameNode(file.destination, other.file.destination)
    }
    func matches(_ url: URL, system: HistorySystem) -> Bool {
        guard let current = system.identity(url) else { return false }
        if let volume { guard volume == system.volume(url) else { return false } }
        else if file.link.device != current.link.device { return false }
        return Self.sameNode(file.link, current.link) && Self.sameNode(file.destination, current.destination)
    }
}

struct HistorySystem {
    var identity: (URL) -> FileIdentity? = FileIdentity.read
    var volume: (URL) -> String? = { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString }
    var bookmark: (URL) throws -> Data = { try $0.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
    var resolve: (Data) throws -> URL = { data in
        var stale = false
        return try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
    var readable: (URL) -> Bool = { FileManager.default.isReadableFile(atPath: $0.path) }
    var unavailable: (URL) -> DirectoryAvailability = { url in
        var link = stat(), target = stat()
        if url.path.withCString({ lstat($0, &link) }) != 0 || url.path.withCString({ stat($0, &target) }) != 0 {
            return errno == EACCES || errno == EPERM ? .permission : .missing
        }
        return .missing
    }

    func capture(_ url: URL, sourceID: String, expected: FileIdentity? = nil) -> HistoryIdentity? {
        guard url.isFileURL, let file = identity(url), expected == nil || file == expected else { return nil }
        return HistoryIdentity(sourceID: sourceID, path: url.path, bookmark: try? bookmark(url), volume: volume(url), file: file)
    }
    func resolve(_ identity: HistoryIdentity) -> (URL, DirectoryAvailability) {
        let fallback = URL(fileURLWithPath: identity.path)
        // Bookmarks may canonicalize /var to /private/var. Keep the indexed spelling
        // while the original path still names the exact captured object.
        if identity.matches(fallback, system: self) { return (fallback, readable(fallback) ? .available : .permission) }
        let url = identity.bookmark.flatMap { try? resolve($0) } ?? fallback
        guard url.isFileURL else { return (fallback, .missing) }
        guard identity.matches(url, system: self) else { return (fallback, unavailable(url)) }
        let originalParent = fallback.deletingLastPathComponent()
        let sameParent = originalParent.resolvingSymlinksInPath().path == url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolved = sameParent ? originalParent.appendingPathComponent(url.lastPathComponent) : url
        return (resolved, readable(resolved) ? .available : .permission)
    }
}
