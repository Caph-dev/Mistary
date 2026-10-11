import Foundation
import Darwin

struct CommandInvocation: Equatable {
    let executable: URL
    let arguments: [String]
    let directory: URL?
    init(definition: ActionDefinition, binding: ActionBinding) throws {
        guard definition.isValid, case .command(let executable, let arguments, let directory) = definition.execution else {
            throw ActionConfigurationError.invalidDefinition
        }
        self.executable = executable
        self.arguments = try arguments.map { try binding.substitute($0) }
        if let directory {
            let path = try binding.substitute(directory)
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ActionConfigurationError.invalidDefinition }
            self.directory = URL(fileURLWithPath: path, isDirectory: true)
        } else { self.directory = nil }
    }
}

struct CommandResult {
    let exitCode: Int32?
    let timedOut: Bool
    let stdout: Data
    let stderr: Data
    let truncated: Bool
    var outputFailed = false
    var outcome: ActionOutcome {
        if timedOut { return .failed(.commandTimedOut) }
        if outputFailed { return .failed(.commandOutputFailed) }
        guard let exitCode else { return .failed(.commandLaunchFailed) }
        // Verification here concerns process termination only, not the script's effects.
        return exitCode == 0 ? .verified : .failed(.commandFailed)
    }
}

enum CommandEvent { case started, finished(CommandResult), cancelled(ActionFailure) }

private final class CommandOutput {
    private let lock = NSLock()
    private var buffers = [Data(), Data()]
    private var clipped = false
    private var stop = false
    private var failed = false
    let limit: Int
    init(limit: Int) { self.limit = max(0, limit) }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }
    func finishReading() { lock.lock(); stop = true; clipped = true; lock.unlock() }
    func readFailed() { lock.lock(); failed = true; lock.unlock() }
    func append(_ data: Data, stream: Int) {
        lock.lock(); defer { lock.unlock() }
        let available = max(0, limit - buffers[stream].count)
        buffers[stream].append(data.prefix(available)); clipped = clipped || data.count > available
    }
    func result(code: Int32?, timedOut: Bool) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        return CommandResult(exitCode: code, timedOut: timedOut, stdout: buffers[0], stderr: buffers[1], truncated: clipped, outputFailed: failed)
    }
}

/// Continuously drains both streams even after retention limits are reached.
final class CommandRunner {
    let outputLimit: Int
    let timeout: TimeInterval
    private let queue: DispatchQueue
    init(outputLimit: Int = 65_536, timeout: TimeInterval = 30, queue: DispatchQueue = DispatchQueue.global(qos: .utility)) {
        self.outputLimit = outputLimit; self.timeout = timeout; self.queue = queue
    }
    func run(_ invocation: CommandInvocation, authorize: @escaping () -> ActionFailure? = { nil }, event: @escaping (CommandEvent) -> Void) {
        queue.async { [self] in
            DispatchQueue.main.async {
                if let failure = authorize() { event(.cancelled(failure)); return }
                self.launch(invocation, event: event)
            }
        }
    }
    // Called immediately after authorization on the main thread. There is no
    // second asynchronous gap between session validation and Process.run().
    private func launch(_ invocation: CommandInvocation, event: @escaping (CommandEvent) -> Void) {
        let process = Process(), out = Pipe(), err = Pipe(), output = CommandOutput(limit: outputLimit)
        process.executableURL = invocation.executable; process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.directory
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            event(.finished(output.result(code: nil, timedOut: false))); return
        }
        let deadline = DispatchTime.now() + timeout
        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
        event(.started)
        queue.async { [self] in
            let readers = DispatchGroup()
            for (index, pipe) in [out, err].enumerated() {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { try? pipe.fileHandleForReading.close(); readers.leave() }
                    let fd = pipe.fileHandleForReading.fileDescriptor
                    guard fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else { output.readFailed(); return }
                    var bytes = [UInt8](repeating: 0, count: 8192)
                    while !output.stopped {
                        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                        if count > 0 { output.append(Data(bytes.prefix(count)), stream: index) }
                        else if count == 0 { break }
                        else if errno == EAGAIN || errno == EINTR {
                            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                            _ = poll(&descriptor, 1, 20)
                        } else { output.readFailed(); break }
                    }
                }
            }
            var timedOut = false
            while process.isRunning {
                if DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                    timedOut = true; process.terminate()
                    let grace = DispatchTime.now() + 0.25
                    while process.isRunning && DispatchTime.now().uptimeNanoseconds < grace.uptimeNanoseconds { Thread.sleep(forTimeInterval: 0.01) }
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
            // A detached descendant can retain a writer; it must not hold our completion forever.
            if readers.wait(timeout: .now() + 0.5) == .timedOut { output.finishReading(); readers.wait() }
            let result = output.result(code: process.terminationStatus, timedOut: timedOut)
            DispatchQueue.main.async { event(.finished(result)) }
        }
    }
}
