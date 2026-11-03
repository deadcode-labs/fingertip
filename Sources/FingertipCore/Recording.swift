//
//  Recording.swift
//  FingertipCore
//
//  Video of the device while the agent works. The simulator is recorded by
//  `simctl io recordVideo`, a child process that only closes its `.mov`
//  cleanly on SIGINT; a Mac app's window by ScreenCaptureKit's
//  `SCRecordingOutput`. One recording per driver at a time. Both recorders are
//  actors: they hold a process or a stream and are awaited from anywhere.
//

import CoreMedia
import Foundation
import ScreenCaptureKit

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
            "Ya hay una grabación en curso (\(url.path)). Detenela con `stop_recording` antes de empezar otra."
        case .notRecording:
            "No hay ninguna grabación en curso."
        case .failed(let detail):
            "La grabación falló: \(detail)"
        }
    }
}

// MARK: - Simulator

actor SimulatorRecorder {
    private var process: Process?
    private var errors: Pipe?
    private var output: URL?

    func start(udid: String, to url: URL) async throws {
        if let output { throw RecordingError.alreadyRecording(output) }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", url.path]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()

        // Claim the state before suspending: a `stop` or a second `start` that runs during the
        // wait below must see this recording, and a cancellation must not leave the process behind.
        self.process = process
        self.errors = errors
        output = url

        // simctl exits at once when the device is not booted or the path is bad;
        // otherwise it keeps running until it is interrupted.
        do {
            try await Task.sleep(for: .milliseconds(700))
        } catch {
            if self.process === process { discard() }
            if process.isRunning { process.interrupt() }
            throw error
        }
        // A `stop` during the wait already took the state (and the process) over.
        guard self.process === process else { return }
        guard process.isRunning else {
            discard()
            let detail = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw RecordingError.failed(detail.isEmpty ? "simctl terminó con \(process.terminationStatus)" : detail)
        }
    }

    private func discard() {
        process = nil
        errors = nil
        output = nil
    }

    func stop() async throws -> URL {
        guard let process, let output else { throw RecordingError.notRecording }
        self.process = nil
        self.output = nil
        let errors = self.errors
        self.errors = nil

        // The `.mov` is only finalised on SIGINT; SIGTERM leaves it unplayable.
        if process.isRunning { process.interrupt() }
        var waited = 0
        while process.isRunning && waited < 100 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        if process.isRunning {
            process.terminate()
            throw RecordingError.failed("simctl no cerró el video en 10 s; el archivo puede no abrir")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            let detail = errors.map { String(decoding: $0.fileHandleForReading.availableData, as: UTF8.self) } ?? ""
            throw RecordingError.failed(detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "el archivo quedó vacío" : detail)
        }
        return output
    }
}

// MARK: - Mac window

/// Receives the end of the recording and any failure of the stream. Callbacks arrive on
/// ScreenCaptureKit's queue, so the state is behind a lock.
nonisolated final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: String?

    var state: (finished: Bool, failure: String?) {
        lock.withLock { (finished, failure) }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { finished = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        lock.withLock { failure = error.localizedDescription }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { failure = error.localizedDescription }
    }
}

actor WindowRecorder {
    private var stream: SCStream?
    private var delegate: RecordingDelegate?
    private var output: URL?

    func start(windowID: CGWindowID, to url: URL) async throws {
        if let output { throw RecordingError.alreadyRecording(output) }
        // Claim the recording before the first suspension, as `SimulatorRecorder` does: a second
        // `start` during the awaits below must see this one, not open a second stream.
        output = url
        var started = false
        defer { if !started { output = nil } }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw RecordingError.failed("la ventana ya no está")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .h264

        let delegate = RecordingDelegate()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        do {
            try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: delegate))
            try await stream.startCapture()
        } catch {
            throw RecordingError.failed(error.localizedDescription)
        }
        self.stream = stream
        self.delegate = delegate
        started = true
    }

    func stop() async throws -> URL {
        guard let stream, let delegate, let output else { throw RecordingError.notRecording }
        self.stream = nil
        self.delegate = nil
        self.output = nil

        // A window closed mid-recording has already stopped the stream: that stop fails, the file is still there.
        try? await stream.stopCapture()
        var waited = 0
        while !delegate.state.finished && waited < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard delegate.state.finished, size > 0 else {
            throw RecordingError.failed(delegate.state.failure ?? "el video no se cerró a tiempo")
        }
        return output
    }
}
