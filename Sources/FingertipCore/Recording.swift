//
//  Recording.swift
//  FingertipCore
//
//  Video of the device while the agent works, always by a child process that
//  only closes its `.mov` cleanly on SIGINT: `simctl io recordVideo` for the
//  simulator, `fingertip-mcp record` (see `WindowCapture`) for a Mac app's
//  window. One recording per driver at a time. The recorder is an actor: it
//  holds the process and is awaited from anywhere.
//

import Darwin
import Foundation

public nonisolated enum RecordingError: FingertipError {
    case alreadyRecording(URL)
    case notRecording
    case failed(String)

    public var code: String {
        switch self {
        case .alreadyRecording: "already_recording"
        case .notRecording: "not_recording"
        case .failed: "recording_failed"
        }
    }

    /// Starting twice or stopping with nothing running is a mistake of the caller, not a transient state.
    public var retrySafe: Bool { false }

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording(let url):
            "A recording is already in progress (\(url.path)). Stop it with `stop_recording` before starting another."
        case .notRecording:
            "No recording in progress."
        case .failed(let detail):
            "The recording failed: \(detail)"
        }
    }
}

actor ProcessRecorder {
    private var process: Process?
    private var errors: Pipe?
    /// Kept open while recording: `fingertip-mcp record` stops when it closes, so a recording
    /// doesn't outlive an MCP that died without stopping it.
    private var input: Pipe?
    /// The child's stdout after its ready line: where `fingertip-mcp record` answers `frame`.
    private var answers: FileHandle?
    /// The `frame` in flight: the next one waits for it, or two answers would interleave.
    private var exchange: Task<Data, any Error>?
    private var output: URL?

    /// Runs `executable` recording to `url`. With `waitsForReady`, it reports it is recording by
    /// writing a line; otherwise (simctl) it is taken as recording if it is still up after 700 ms.
    func start(_ executable: URL, _ arguments: [String], to url: URL, waitsForReady: Bool) async throws {
        if let output { throw RecordingError.alreadyRecording(output) }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errors = Pipe()
        let input = Pipe()
        let ready = Pipe()
        process.standardInput = input
        process.standardOutput = waitsForReady ? ready : FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        // The child has its own copy; with this one open, a child that exits without writing
        // would never close the pipe, and the wait below would never end.
        try? ready.fileHandleForWriting.close()

        // Claim the state before suspending: a `stop` or a second `start` that runs during the
        // wait below must see this recording, and a cancellation must not leave the process behind.
        self.process = process
        self.errors = errors
        self.input = input
        answers = waitsForReady ? ready.fileHandleForReading : nil
        output = url

        // Both exit at once when the device or the window is not there, or the path is bad;
        // otherwise they keep running until interrupted.
        let started: Bool
        if waitsForReady {
            started = await Self.readsLine(ready.fileHandleForReading, pid: process.processIdentifier, within: .seconds(10))
        } else {
            started = (try? await Task.sleep(for: .milliseconds(700))) != nil
        }
        if Task.isCancelled {
            if self.process === process { discard() }
            if process.isRunning { process.interrupt() }
            throw CancellationError()
        }
        // A `stop` during the wait already took the state (and the process) over.
        guard self.process === process else { return }
        guard started, process.isRunning else {
            discard()
            // Killed by `readsLine` after 10 s, or exiting on its own: let it finish so stderr is complete.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            let detail = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecordingError.failed(detail.isEmpty
                ? (started ? "the recorder exited with \(process.terminationStatus)" : "the recording didn't start within 10 s")
                : detail)
        }
    }

    /// Whether `handle` gets a line before it closes. After `timeout` the process is killed,
    /// which closes it. Read on a thread of its own, off the cooperative pool.
    private static func readsLine(_ handle: FileHandle, pid: pid_t, within timeout: Duration) async -> Bool {
        let deadline = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            kill(pid, SIGKILL)
        }
        defer { deadline.cancel() }
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: !handle.availableData.isEmpty)
            }
        }
    }

    private func discard() {
        process = nil
        errors = nil
        input = nil
        answers = nil
        exchange = nil
        output = nil
    }

    /// The recorded window's latest frame as a PNG, from the running `fingertip-mcp record`;
    /// `crop` is a sheet's place in that window. `nil` when no such recorder is running.
    func frame(crop: CGRect?) async throws -> Data? {
        guard let process, process.isRunning, let input else { return nil }
        // After an answer that went wrong the channel may be out of step: no more questions.
        guard let answers else { throw RecordingError.failed("the recorder stopped answering screenshots") }
        var line = try JSONEncoder().encode(FrameRequest(crop: crop))
        line.append(UInt8(ascii: "\n"))
        let previous = exchange
        let task = Task {
            _ = await previous?.result
            return try await Self.ask(line, input: input.fileHandleForWriting, answers: answers)
        }
        exchange = task
        do {
            return try await task.value
        } catch {
            if self.process === process { self.answers = nil }
            throw error
        }
    }

    /// Writes `request` and reads the answer, on a thread of its own, off the cooperative pool.
    /// A child that doesn't answer within 5 s is left recording: killing it would lose the video.
    private static func ask(_ request: Data, input: FileHandle, answers: FileHandle) async throws -> Data {
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                once.resume(continuation) {
                    try input.write(contentsOf: request)
                    guard let header = readLine(answers) else {
                        throw RecordingError.failed("the recorder closed while answering a screenshot")
                    }
                    if header.hasPrefix("error ") { throw RecordingError.failed(String(header.dropFirst(6))) }
                    guard header.hasPrefix("png "), let count = Int(header.dropFirst(4)),
                          let png = try answers.read(upToCount: count), png.count == count
                    else { throw RecordingError.failed("the recorder answered a screenshot with «\(header)»") }
                    return png
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                once.resume(continuation) {
                    throw RecordingError.failed("the recorder didn't answer a screenshot within 5 s")
                }
            }
        }
    }

    /// One line from `handle` without its newline, read byte by byte so nothing past it is taken.
    private static func readLine(_ handle: FileHandle) -> String? {
        var bytes = Data()
        while let byte = try? handle.read(upToCount: 1), let first = byte.first {
            if first == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(first)
        }
        return nil
    }

    func stop() async throws -> URL {
        guard let process, let output else { throw RecordingError.notRecording }
        self.process = nil
        self.output = nil
        let errors = self.errors
        self.errors = nil
        // Closed only once it has exited: closing it is also a stop for `fingertip-mcp record`.
        let input = self.input
        self.input = nil
        answers = nil
        exchange = nil

        // The `.mov` is only finalised on SIGINT; SIGTERM leaves it unplayable.
        if process.isRunning { process.interrupt() }
        var waited = 0
        while process.isRunning && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        if process.isRunning {
            // SIGKILL: `fingertip-mcp record` takes SIGTERM as one more request to stop, and it is
            // already stuck stopping.
            kill(process.processIdentifier, SIGKILL)
            throw RecordingError.failed("the recorder didn't close the video within 10 s; the file may not open")
        }
        withExtendedLifetime(input) {}
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        // A recording cut short (`replayd` died under `fingertip-mcp record`) leaves a file that
        // doesn't open; the recorder exits with an error then.
        guard process.terminationStatus == 0, size > 0 else {
            let detail = errors.map { String(decoding: $0.fileHandleForReading.availableData, as: UTF8.self) } ?? ""
            let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecordingError.failed(size == 0 ? "the file is empty" : "\(reason.isEmpty ? "the recorder exited with \(process.terminationStatus)" : reason): \(output.path)")
        }
        return output
    }
}

/// Resumes a continuation once: the first of the answer and the timeout wins.
private nonisolated final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume<T: Sendable>(_ continuation: CheckedContinuation<T, any Error>, with body: () throws -> T) {
        let result = Result(catching: body)
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { continuation.resume(with: result) }
    }
}
