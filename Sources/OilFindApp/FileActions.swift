import Foundation
import Darwin

/// Main-thread invalidation cancels a permit until the worker claims it.
/// Claiming defines the operation boundary; later invalidation cannot undo I/O.
final class FileMutationPermit {
    private let lock = NSLock()
    private var cancelled = false, claimed = false
    func cancel() { lock.lock(); defer { lock.unlock() }; if !claimed { cancelled = true } }
    func begin() -> ActionFailure? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return .staleSession }
        guard !claimed else { return .alreadyDispatched }
        claimed = true; return nil
    }
}

struct FileMutation {
    let request: ActionRequest
    let parent: URL
    let parentIdentity: FileIdentity?
    init(request: ActionRequest) {
        self.request = request
        parent = request.action == .createDirectory && request.target.isDirectory
            ? request.target.url : request.target.url.deletingLastPathComponent()
        parentIdentity = FileIdentity.read(parent)
    }
}

struct FileMutationSystem {
    var beforeOperation: () -> Void = {}
    var mkdir: (Int32, String) -> Int32 = { fd, name in name.withCString { mkdirat(fd, $0, 0o755) } }
    var rename: (Int32, String, String) -> Int32 = { fd, from, to in
        from.withCString { old in to.withCString { new in renameatx_np(fd, old, fd, new, UInt32(RENAME_EXCL)) } }
    }
}

/// All disk work is descriptor-relative and happens outside index read locks.
final class FileActions {
    private let queue: DispatchQueue
    var system = FileMutationSystem()
    init(queue: DispatchQueue = DispatchQueue(label: "me.caph.mistary.file-actions", qos: .userInitiated)) { self.queue = queue }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.utf8.contains(0)
            && name.utf8.count <= 255
    }
    static func availability(_ mutation: FileMutation) -> ActionFailure? {
        guard let target = mutation.request.target.identity, target.link == target.destination,
              let parent = mutation.parentIdentity, parent.link == parent.destination else { return .symlinkUnsupported }
        return nil
    }
    func perform(_ mutation: FileMutation, name: String, authorize: @escaping () -> ActionFailure? = { nil }, begin: @escaping () -> ActionFailure? = { nil }, completion: @escaping (ActionOutcome) -> Void) {
        let system = self.system
        queue.async { [self] in
            // Revisit main-owned source and session state after any queue backlog.
            DispatchQueue.main.async {
                if let failure = authorize() { completion(.cancelled(failure)); return }
                self.queue.async {
                    let outcome: ActionOutcome
                    if let failure = begin() { outcome = .cancelled(failure) }
                    else { outcome = Self.performNow(mutation, name: name, system: system) }
                    DispatchQueue.main.async { completion(outcome) }
                }
            }
        }
    }
    static func performNow(_ mutation: FileMutation, name: String, system: FileMutationSystem = FileMutationSystem()) -> ActionOutcome {
        guard validName(name) else { return .failed(.invalidName) }
        if let failure = availability(mutation) { return .failed(failure) }
        let request = mutation.request, target = request.target
        guard request.action == .rename || request.action == .createDirectory else { return .failed(.unsupportedAction) }
        guard let parentIdentity = mutation.parentIdentity,
              FileIdentity.read(mutation.parent) == parentIdentity else { return .cancelled(.targetChanged) }
        let parent = mutation.parent.resolvingSymlinksInPath()
        let fd = parent.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return .failed(failure(errno)) }
        defer { close(fd) }
        var parentStat = stat()
        guard fstat(fd, &parentStat) == 0, FileIdentity.Node(parentStat) == parentIdentity.destination else { return .cancelled(.targetChanged) }
        system.beforeOperation()
        guard FileIdentity.read(mutation.parent) == parentIdentity,
              FileIdentity.read(target.url) == target.identity else { return .cancelled(.targetChanged) }
        // RENAME_EXCL prevents atomic destination replacement. POSIX provides no
        // compare-inode-and-rename operation; a concurrent source change after this
        // check remains a filesystem limitation, not an overwrite fallback.
        if request.action == .rename {
            var sourceStat = stat()
            let source = target.url.lastPathComponent
            guard source.withCString({ fstatat(fd, $0, &sourceStat, AT_SYMLINK_NOFOLLOW) }) == 0,
                  FileIdentity.Node(sourceStat) == target.identity?.link else { return .cancelled(.targetChanged) }
            if source == name { return .verified }
            let destination = parent.appendingPathComponent(name)
            if let existing = FileIdentity.read(destination), existing.link == target.identity?.link {
                // Includes case-only renames on case-insensitive volumes.
                return .failed(.caseRenameUnsupported)
            }
            guard system.rename(fd, source, name) == 0 else { return .failed(failure(errno)) }
            var moved = stat()
            guard name.withCString({ fstatat(fd, $0, &moved, AT_SYMLINK_NOFOLLOW) }) == 0,
                  FileIdentity.Node(moved) == target.identity?.link else { return .failed(.mutationNotVerified) }
        } else {
            // mkdirat fails with EEXIST even if another writer wins the race.
            guard system.mkdir(fd, name) == 0 else { return .failed(failure(errno)) }
            var created = stat()
            guard name.withCString({ fstatat(fd, $0, &created, AT_SYMLINK_NOFOLLOW) }) == 0,
                  created.st_mode & S_IFMT == S_IFDIR else { return .failed(.mutationNotVerified) }
        }
        return .verified
    }
    private static func failure(_ code: Int32) -> ActionFailure {
        switch code {
        case EEXIST, ENOTEMPTY: return .destinationExists
        case EACCES, EPERM, EROFS: return .permissionDenied
        case ENOENT: return .fileUnavailable
        case ENOTSUP, EINVAL: return .unsupportedAction
        default: return .systemRejected
        }
    }
}
