import Foundation
import COilFind

/// A lexical absolute directory path. Symlinks are never resolved across index boundaries.
public struct DirectoryScope: Equatable {
    public let path: String
    public init(path: String) {
        guard path.hasPrefix("/") else { self.path = ""; return }
        var components: [Substring] = []
        for component in path.precomposedStringWithCanonicalMapping.split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(component) }
        }
        self.path = "/" + components.joined(separator: "/")
    }
}

/// Compiled only under the source store's read lock; never retained across searches.
struct CompiledDirectoryScope {
    private let root: UInt32?
    private let unrestricted: Bool
    init(_ scope: DirectoryScope?, store: IndexStore) {
        guard let scope else { root = nil; unrestricted = true; return }
        unrestricted = false
        let requested = scope.path.split(separator: "/").map { Array($0.utf8) }
        let base = store.rootPath.precomposedStringWithCanonicalMapping.split(separator: "/").map { Array($0.utf8) }
        func equal(_ a: [UInt8], _ b: [UInt8]) -> Bool {
            a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in
                sift_name_equal(x.baseAddress, x.count, y.baseAddress, y.count, store.caseSensitiveNames ? 1 : 0) != 0
            } }
        }
        guard !scope.path.isEmpty, store.count > 0, store.isLive(0),
              zip(requested, base).allSatisfy({ equal($0, $1) }) else { root = nil; return }
        if requested.count <= base.count { root = 0; return }
        var current: UInt32 = 0
        for component in requested.dropFirst(base.count) {
            guard store.flags[Int(current)] & (SiftFlag.dir | SiftFlag.symlink) == SiftFlag.dir else { root = nil; return }
            let child: UInt32? = component.withUnsafeBufferPointer { bytes in
                if store.hashReady { return store.lookup(parent: current, name: bytes) }
                for i in (Int(current) + 1)..<store.count where store.parent[i] == current && store.isLive(UInt32(i)) {
                    let candidate = store.nameBytes(UInt32(i))
                    if sift_name_equal(candidate.baseAddress, candidate.count, bytes.baseAddress, bytes.count, store.caseSensitiveNames ? 1 : 0) != 0 { return UInt32(i) }
                }
                return nil
            }
            guard let child else { root = nil; return }; current = child
        }
        root = store.flags[Int(current)] & (SiftFlag.dir | SiftFlag.symlink) == SiftFlag.dir ? current : nil
    }
    var isAvailable: Bool { unrestricted || root != nil }
    @inline(__always) func contains(_ id: UInt32, store: IndexStore) -> Bool {
        if unrestricted { return true }
        guard let root else { return false }
        var current = id
        while current > root { current = store.parent[Int(current)] }
        return current == root
    }
}
