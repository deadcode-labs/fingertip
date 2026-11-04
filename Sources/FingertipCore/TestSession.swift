//
//  TestSession.swift
//  FingertipCore
//
//  One test, from `connect(test:)` to `end_test`: a folder that keeps what the test produced.
//
//      tests/<date>-<name>/
//        test.json      name, target, start, end, verdict, notes
//        trace.jsonl    one line per tool call
//        screens/       the screen after each call, deduplicated by hash
//        recording.mov  the video of the whole test
//        jev/           the `run_instruction` runs started during the test
//
//  It lives under Application Support, not `$TMPDIR`: macOS empties the temporary folder on
//  its own, and tests are meant to be looked at later.
//

import Foundation

public final class TestSession {
    public static let directory = URL.applicationSupportDirectory
        .appending(path: "Fingertip/tests", directoryHint: .isDirectory)

    public let name: String
    public let folder: URL
    public var recording: URL { folder.appending(path: "recording.mov") }
    public var jevDirectory: URL { folder.appending(path: "jev", directoryHint: .isDirectory) }

    private let trace: RunLog
    private var summary: [String: Any]

    public init(name: String, target: String) throws {
        let stem = "\(RunLog.stamp())-\(Self.slug(name))"
        var folder = Self.directory.appending(path: stem, directoryHint: .isDirectory)
        var suffix = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = Self.directory.appending(path: "\(stem)-\(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        self.name = name
        self.folder = folder
        trace = RunLog(file: folder.appending(path: "trace.jsonl"),
                       screenshots: folder.appending(path: "screens", directoryHint: .isDirectory))
        summary = ["name": name, "target": target, "started": Date.now.formatted(.iso8601)]
        writeSummary()
    }

    /// The recording could not start (a Mac app with no window chosen yet, a missing
    /// permission): the test goes on without video, and `test.json` says why.
    public func recordingFailed(_ reason: String) {
        summary["recording_error"] = reason
        writeSummary()
    }

    /// One tool call. The screen after it is saved once per distinct image.
    public func record(tool: String, arguments: [String: Any], text: String, errorCode: String?,
                       milliseconds: Int, screen: Data?) async {
        var entry: [String: Any] = ["tool": tool, "arguments": arguments, "result": text, "ms": milliseconds]
        if let errorCode { entry["error"] = errorCode }
        if let screen, let shot = await trace.saveScreenshot(screen) { entry["screen"] = shot.name }
        await trace.append(entry)
    }

    /// `passed` nil: the test was closed without a verdict (a new `connect`, the server closing).
    public func finish(passed: Bool?, notes: String?) {
        summary["ended"] = Date.now.formatted(.iso8601)
        summary["verdict"] = passed.map { $0 ? "passed" : "failed" } ?? "none"
        if let notes, !notes.isEmpty { summary["notes"] = notes }
        writeSummary()
    }

    private func writeSummary() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: folder.appending(path: "test.json"))
    }

    /// `Login con email inválido` → `login-con-email-invalido`.
    private static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let words = folded.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
        let slug = String(words.joined(separator: "-").prefix(48))
        return slug.isEmpty ? "test" : slug
    }
}
