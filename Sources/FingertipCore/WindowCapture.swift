//
//  WindowCapture.swift
//  FingertipCore
//
//  ScreenCaptureKit runs in a child process (`fingertip-mcp capture` and
//  `fingertip-mcp record`), never in the MCP itself. A process that has used it
//  keeps a connection to `replayd`, and when macOS restarts `replayd` that
//  connection reconnects in a loop for as long as the process lives: days, for
//  an MCP tied to a Claude Code session. `replayd` then sits at full CPU and every
//  capture on the Mac stalls behind it. A child that exits takes its connection
//  with it. The MCP finds the window through Accessibility and hands the child
//  what it needs to match it in ScreenCaptureKit.
//

import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// The window to capture, as the MCP sees it through Accessibility. Goes to the child as JSON.
nonisolated struct CaptureTarget: Codable, Sendable {
    let pid: pid_t
    let bundleID: String
    /// Matched by number when the window has one: two windows of one app can share a frame.
    let number: CGWindowID?
    /// The window's frame; for a sheet, its parent's.
    let frame: CGRect
    /// For a sheet: where it sits inside `frame`, to be cropped out of the capture.
    var crop: CGRect?
}

public nonisolated enum WindowCapture {
    /// The child's exit status when ScreenCaptureKit has no window that matches the target.
    static let notCapturableStatus: Int32 = 3

    /// The MCP's own binary, which `MacDriver` only runs inside.
    static var helper: URL {
        Bundle.main.executableURL ?? URL(filePath: CommandLine.arguments[0])
    }

    /// Runs the child's subcommand when `arguments` (the process arguments after the executable)
    /// name one, and returns its exit status; `nil` when they don't. `output` is the child's
    /// stdout, a pipe to the MCP: the PNG for `capture`, a line once `record` is recording.
    /// Failures go to stderr.
    public static func runChild(_ arguments: [String], output: FileHandle) async -> Int32? {
        guard let command = arguments.first, ["capture", "record"].contains(command) else { return nil }
        // ScreenCaptureKit asserts in `CGS_REQUIRE_INIT` without a window server connection, which
        // this opens. Not `NSApplication.shared`, as the MCP does: that registers the child with
        // LaunchServices, and every child coming and going empties the MCP's
        // `NSRunningApplication` lists for a moment, so the app looked not running.
        _ = CGMainDisplayID()
        do {
            guard arguments.count >= 2,
                  let target = try? JSONDecoder().decode(CaptureTarget.self, from: Data(arguments[1].utf8))
            else { throw ChildFailure.failed("bad arguments") }
            if command == "capture" {
                output.write(try await capture(target))
            } else {
                guard arguments.count >= 3 else { throw ChildFailure.failed("no output path") }
                try await record(target, to: URL(filePath: arguments[2]), output: output)
            }
            return 0
        } catch ChildFailure.notCapturable {
            // The MCP names the app from the status; the text is for a recording's error.
            FileHandle.standardError.write(Data("ScreenCaptureKit can't see the window (on another Space, or gone)".utf8))
            return notCapturableStatus
        } catch ChildFailure.failed(let detail) {
            FileHandle.standardError.write(Data(detail.utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data(error.localizedDescription.utf8))
            return 1
        }
    }

    private enum ChildFailure: Error {
        case notCapturable
        case failed(String)
    }

    // MARK: - Child

    private static func window(for target: CaptureTarget) async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if let number = target.number {
            guard let window = content.windows.first(where: { $0.windowID == number }), window.frame == target.frame else {
                throw ChildFailure.notCapturable
            }
            return window
        }
        // Only the app's windows or its extensions': two maximised windows share a frame, and
        // without this Chrome's slipped in.
        let matches = content.windows.filter { window in
            guard window.windowLayer == 0, window.frame == target.frame, let owner = window.owningApplication else { return false }
            return owner.processID == target.pid || owner.bundleIdentifier.hasPrefix(target.bundleID + ".")
        }
        guard let window = matches.first(where: { $0.owningApplication?.processID == target.pid }) ?? matches.first else {
            throw ChildFailure.notCapturable
        }
        return window
    }

    private static func capture(_ target: CaptureTarget) async throws -> Data {
        let filter = SCContentFilter(desktopIndependentWindow: try await window(for: target))
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false

        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        if let crop = target.crop {
            let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            guard let sheet = image.cropping(to: pixels) else { throw ChildFailure.failed("couldn't crop the sheet") }
            image = sheet
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ChildFailure.failed("couldn't encode the PNG")
        }
        return png
    }

    /// Records until SIGINT or SIGTERM, until stdin closes because the MCP is gone, or until the
    /// stream fails, then closes the `.mov`; a stream that failed first is an error, so a video
    /// cut short doesn't pass for a whole one.
    ///
    /// While it records it also serves the MCP's screenshots of the window: when another process
    /// of this binary closes its ScreenCaptureKit connection, `replayd` interrupts this stream
    /// too, so a `capture` child per screenshot would cut the video at the first one. Each line
    /// on stdin is a `FrameRequest` in JSON; the answer on stdout is `png <byte count>\n` and the
    /// PNG, or `error <reason>\n`.
    private static func record(_ target: CaptureTarget, to url: URL, output: FileHandle) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: try await window(for: target))
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        // `LatestFrame` holds on to one buffer of the pool the recording also draws from.
        configuration.queueDepth = 6

        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .h264

        // `true` when the MCP asked to stop, `false` when the stream failed.
        let (stops, stop) = AsyncStream.makeStream(of: Bool.self)
        // The stream fails when `replayd` dies or the window closes. The child ends at once then:
        // one left running stalls the next capture child, which `replayd` takes for the same client.
        let delegate = RecordingDelegate { stop.yield(false) }
        let frames = LatestFrame()
        let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: delegate))
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: DispatchQueue(label: "fingertip-record.frames"))
        try await stream.startCapture()
        output.write(Data("recording\n".utf8))

        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stop.yield(true) }
            source.resume()
            return source
        }
        Thread.detachNewThread {
            while let line = readLine() {
                // Drained per answer: the image and the PNG keep the frame's buffer alive, and
                // with a few of those held the recording stops writing while the stream goes on.
                output.write(autoreleasepool { answer(line, frames: frames, scale: scale) })
            }
            stop.yield(true)
        }
        var requested = true
        for await reason in stops {
            requested = reason
            break
        }
        withExtendedLifetime(signals) {}

        // A window closed mid-recording has already stopped the stream: that stop fails, the file
        // is still there. Not awaited: without `replayd` it never returns, and the wait below is bounded.
        Task { try? await stream.stopCapture() }
        var waited = 0
        while !delegate.state.finished && delegate.state.failure == nil && waited < 200 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        guard delegate.state.finished else {
            throw ChildFailure.failed(delegate.state.failure ?? "the video wasn't closed in time")
        }
        guard requested else {
            throw ChildFailure.failed("the recording stopped by itself (the window closed, or `replayd` cut it: \(delegate.state.failure ?? "no reason given")); the file keeps what was recorded until then")
        }
    }

    /// The answer to one line of the MCP: the window's latest frame as a PNG, cropped to the
    /// request's sheet.
    private static func answer(_ line: String, frames: LatestFrame, scale: CGFloat) -> Data {
        guard let request = try? JSONDecoder().decode(FrameRequest.self, from: Data(line.utf8)) else {
            return Data("error bad request\n".utf8)
        }
        // The first frame arrives a few milliseconds after `startCapture`.
        var waited = 0
        while frames.current == nil && waited < 40 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
        var image: CGImage?
        guard let pixels = frames.current,
              VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr,
              var image
        else { return Data("error no frame from the recording yet\n".utf8) }
        if let crop = request.crop {
            let rect = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale)
            guard let sheet = image.cropping(to: rect) else { return Data("error couldn't crop the sheet\n".utf8) }
            image = sheet
        }
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            return Data("error couldn't encode the PNG\n".utf8)
        }
        return Data("png \(png.count)\n".utf8) + png
    }
}

/// A screenshot asked of a running `fingertip-mcp record`: for a sheet, where it sits in the
/// recorded window.
nonisolated struct FrameRequest: Codable, Sendable {
    var crop: CGRect?
}

/// The stream's latest complete frame. ScreenCaptureKit only sends a new one when the window
/// changes, so the last complete one is what the window shows. Callbacks arrive on the stream's
/// queue; the buffer is behind a lock.
nonisolated final class LatestFrame: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    var current: CVPixelBuffer? { lock.withLock { buffer } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)),
              status == .complete,
              let pixels = sampleBuffer.imageBuffer
        else { return }
        lock.withLock { buffer = pixels }
    }
}

/// Receives the end of the recording and any failure of the stream. Callbacks arrive on
/// ScreenCaptureKit's queue, so the state is behind a lock.
nonisolated final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: String?
    private let failed: @Sendable () -> Void

    /// `failed` is called when the stream or the recording fails.
    init(failed: @escaping @Sendable () -> Void) {
        self.failed = failed
    }

    var state: (finished: Bool, failure: String?) {
        lock.withLock { (finished, failure) }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.withLock { finished = true }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        lock.withLock { failure = error.localizedDescription }
        failed()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.withLock { failure = error.localizedDescription }
        failed()
    }
}
