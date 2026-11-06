//
//  Subprocess.swift
//  FingertipCore
//
//  Runs a short command (sim-use, xcrun simctl) with a deadline. The MCP serves one
//  message at a time, so a command that never returns would hang every tool after it.
//  The pipes are drained on their own threads, off the cooperative pool and in
//  parallel, so neither a slow command nor a full stderr buffer can block a caller.
//

import Darwin
import Foundation

nonisolated struct SubprocessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

/// A command that ran past its deadline and was killed.
public nonisolated struct SubprocessTimeout: FingertipError {
    /// The command without its arguments (`sim-use type`), for the message: an argument can be
    /// the text being typed, a password included, and this message reaches logs and the caller.
    public let command: String
    public let seconds: Int
    /// A read that timed out changed nothing; an action may have landed before the hang.
    public let isRead: Bool

    public var code: String { "process_timed_out" }
    public var retrySafe: Bool { isRead }

    public var errorDescription: String? {
        let tail = isRead
            ? "Try again; if it happens again, the simulator may be stuck (erase it with `xcrun simctl erase`)."
            : "The action may have landed before the hang: read the screen again before repeating it."
        return "`\(command)` didn't finish within \(seconds) s and was killed. \(tail)"
    }
}

nonisolated enum Subprocess {
    /// Runs `executable` and returns what it wrote. Throws `SubprocessTimeout` if it is still
    /// running after `timeout`: it gets SIGTERM, then SIGKILL two seconds later. A cancelled
    /// caller gets the same treatment for the command and `CancellationError`.
    /// `label` names the command in a timeout error and must carry no argument values.
    /// `isRead` says whether a timeout is safe to retry. Failing to start rethrows
    /// `Process.run`'s error.
    static func run(
        _ executable: URL, _ arguments: [String], label: String, timeout: Duration, isRead: Bool
    ) async throws -> SubprocessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        // Set before `run`, so an exit that comes at once is not missed.
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { finished in
            exited.yield(finished.terminationStatus)
            exited.finish()
        }
        try process.run()

        let pid = process.processIdentifier
        let stdout = drain(output.fileHandleForReading)
        let stderr = drain(errors.fileHandleForReading)

        // Fires only if the command outlives the deadline; cancelled as soon as it exits.
        let watchdog = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            await terminateTree(of: pid)
            return true
        }

        // Unstructured, so the caller's cancellation does not end the wait (an `AsyncStream`
        // iteration stops when its task is cancelled): the command is killed instead, and its
        // exit still arrives.
        let exit = Task { () -> Int32 in
            var status: Int32 = -1
            for await code in exits { status = code }
            return status
        }
        let status = await withTaskCancellationHandler {
            await exit.value
        } onCancel: {
            // SIGTERM only: a later SIGKILL could hit a pid reused after the exit. A command that
            // ignores SIGTERM is still killed by the watchdog at its deadline.
            signalTree(of: pid, SIGTERM)
        }
        watchdog.cancel()

        // In both cases the readers are left to finish on their own: a child of the command may
        // still hold the pipe open, and waiting on it is the hang this exists to avoid.
        if await watchdog.value {
            throw SubprocessTimeout(command: label, seconds: Int(timeout.components.seconds), isRead: isRead)
        }
        try Task.checkCancellation()
        return SubprocessOutput(status: status, stdout: await stdout.value, stderr: await stderr.value)
    }

    /// SIGTERM to `pid` and everything below it, then SIGKILL two seconds later unless the
    /// calling task is cancelled first, which `run` does once the command has exited.
    private static func terminateTree(of pid: pid_t) async {
        let tree = signalTree(of: pid, SIGTERM)
        guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
        tree.forEach { kill($0, SIGKILL) }
    }

    /// Sends `signal` to `pid` and everything below it, and returns them. The tree is gathered
    /// before anything dies: once the command exits its children are reparented to launchd and
    /// no longer found under it, yet they keep running.
    @discardableResult
    private static func signalTree(of pid: pid_t, _ signal: Int32) -> [pid_t] {
        let tree = descendants(of: pid) + [pid]
        tree.forEach { kill($0, signal) }
        return tree
    }

    /// Every process below `pid`, deepest first.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 256)
        let found = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        return children.prefix(Int(found)).filter { $0 > 0 }.flatMap { descendants(of: $0) + [$0] }
    }

    /// Reads `handle` to its end on a thread of its own.
    private static func drain(_ handle: FileHandle) -> Task<Data, Never> {
        Task {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
                }
            }
        }
    }
}
