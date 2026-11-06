//
//  TestLibrary.swift
//  FingertipCore
//
//  The read side of the folder `TestSession` writes: lists the saved tests and loads one
//  test's steps, for the app's tests window. Read-only.
//
//  Nothing here throws or drops data: a folder whose `test.json` is missing or broken is
//  still listed (with `problem` set), and a trace line that doesn't decode is kept as a
//  broken step, so the UI can show what is wrong instead of hiding it.
//

import Foundation

/// One test folder under `TestSession.directory`.
public nonisolated struct TestSummary: Identifiable, Hashable, Sendable {
    public enum Verdict: String, Hashable, Sendable {
        case passed
        case failed
        /// Closed without a verdict (a new `connect`, the server closing).
        case none
        /// No `ended` in `test.json` yet: the test is open, or the server died mid-test.
        case inProgress
        /// `test.json` is missing or doesn't decode.
        case unknown
    }

    public var id: URL { folder }
    public let folder: URL
    /// From `test.json`; the folder name when it can't be read.
    public let name: String
    public let target: String?
    public let started: Date?
    public let ended: Date?
    public let verdict: Verdict
    public let notes: String?
    public let recordingError: String?
    /// Why `test.json` couldn't be read (missing, not JSON, not an object). Nil when it was fine.
    public let problem: String?

    public let traceFile: URL
    public let hasTrace: Bool
    public let screensDirectory: URL
    /// `recording.mov`, nil when the file doesn't exist.
    public let recording: URL?
    public let jevDirectory: URL
    /// `jev/` exists and has at least one run in it.
    public let hasJevRuns: Bool

    /// `ended - started`; nil while in progress or when either date is unknown.
    public var duration: TimeInterval? {
        guard let started, let ended else { return nil }
        return ended.timeIntervalSince(started)
    }
}

/// One line of a test's `trace.jsonl`: a tool call.
public nonisolated struct TestStep: Identifiable, Hashable, Sendable {
    public nonisolated struct Argument: Hashable, Sendable {
        public let key: String
        /// Strings as they are; anything else as compact JSON.
        public let value: String
    }

    /// The line's position among the trace's non-empty lines, from 0.
    public let id: Int
    /// Empty for a broken line.
    public let tool: String
    /// Sorted by key.
    public let arguments: [Argument]
    public let result: String
    /// The MCP error code, nil when the call succeeded.
    public let errorCode: String?
    public let milliseconds: Int?
    public let at: Date?
    /// The path the line gives for its screen, relative to the test folder (`screens/001.png`).
    public let screenName: String?
    /// The screen image, nil when the line has none or the file is missing.
    public let screen: URL?
    /// Why the line couldn't be decoded. Nil when it was fine.
    public let problem: String?
    /// The line as written, kept so a broken one can be shown.
    public let raw: String

    /// The line names a screen that isn't in `screens/`.
    public var screenMissing: Bool { screenName != nil && screen == nil }
}

public nonisolated enum TestLibrary {
    /// Every test folder in `directory`, newest first. An absent directory is an empty list.
    public static func list(in directory: URL) -> [TestSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let tests = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { summary(of: $0) }

        // `started` first; for a broken `test.json` the folder's creation date stands in.
        func sortDate(_ test: TestSummary) -> Date {
            test.started
                ?? (try? test.folder.resourceValues(forKeys: [.creationDateKey]).creationDate)
                ?? .distantPast
        }
        return tests
            .map { (test: $0, date: sortDate($0)) }
            .sorted { $0.date != $1.date ? $0.date > $1.date : $0.test.folder.lastPathComponent > $1.test.folder.lastPathComponent }
            .map(\.test)
    }

    /// The tests in `TestSession.directory`, newest first.
    @MainActor public static func list() -> [TestSummary] {
        list(in: TestSession.directory)
    }

    /// Reads one test folder. Never fails: what can't be read is reported in `problem`.
    public static func summary(of folder: URL) -> TestSummary {
        let fm = FileManager.default
        let traceFile = folder.appending(path: "trace.jsonl")
        let screens = folder.appending(path: "screens", directoryHint: .isDirectory)
        let recording = folder.appending(path: "recording.mov")
        let jev = folder.appending(path: "jev", directoryHint: .isDirectory)
        let jevRuns = (try? fm.contentsOfDirectory(atPath: jev.path))?.contains { !$0.hasPrefix(".") } ?? false

        var json: [String: Any] = [:]
        var problem: String?
        let file = folder.appending(path: "test.json")
        if let data = try? Data(contentsOf: file) {
            if let object = try? JSONSerialization.jsonObject(with: data) {
                if let dictionary = object as? [String: Any] {
                    json = dictionary
                } else {
                    problem = "test.json is not a JSON object"
                }
            } else {
                problem = "test.json is not valid JSON"
            }
        } else {
            problem = fm.fileExists(atPath: file.path) ? "test.json can't be read" : "test.json is missing"
        }

        let ended = date(json["ended"])
        let verdict: TestSummary.Verdict
        if problem != nil {
            verdict = .unknown
        } else if ended == nil {
            verdict = .inProgress
        } else {
            verdict = (json["verdict"] as? String).flatMap(TestSummary.Verdict.init(rawValue:)) ?? .none
        }

        return TestSummary(
            folder: folder,
            name: (json["name"] as? String) ?? folder.lastPathComponent,
            target: json["target"] as? String,
            started: date(json["started"]),
            ended: ended,
            verdict: verdict,
            notes: json["notes"] as? String,
            recordingError: json["recording_error"] as? String,
            problem: problem,
            traceFile: traceFile,
            hasTrace: fm.fileExists(atPath: traceFile.path),
            screensDirectory: screens,
            recording: fm.fileExists(atPath: recording.path) ? recording : nil,
            jevDirectory: jev,
            hasJevRuns: jevRuns
        )
    }

    /// The test's trace, in order. A missing trace is no steps; a line that doesn't decode is
    /// a step with `problem` set.
    public static func steps(of test: TestSummary) -> [TestStep] {
        guard let data = try? Data(contentsOf: test.traceFile) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.enumerated().map { step(index: $0.offset, line: $0.element, test: test) }
    }

    private static func step(index: Int, line: String, test: TestSummary) -> TestStep {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let json = object as? [String: Any],
              let tool = json["tool"] as? String
        else {
            return TestStep(id: index, tool: "", arguments: [], result: "", errorCode: nil,
                            milliseconds: nil, at: nil, screenName: nil, screen: nil,
                            problem: "broken trace.jsonl line", raw: line)
        }

        let arguments = ((json["arguments"] as? [String: Any]) ?? [:])
            .map { TestStep.Argument(key: $0.key, value: render($0.value)) }
            .sorted { $0.key < $1.key }
        let screenName = json["screen"] as? String
        // `RunLog` writes it relative to the test folder; a bare file name is taken as in `screens/`.
        let screen = screenName.map {
            $0.contains("/") ? test.folder.appending(path: $0) : test.screensDirectory.appending(path: $0)
        }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        return TestStep(
            id: index,
            tool: tool,
            arguments: arguments,
            result: (json["result"] as? String) ?? "",
            errorCode: json["error"] as? String,
            milliseconds: (json["ms"] as? NSNumber)?.intValue,
            at: date(json["at"]),
            screenName: screenName,
            screen: screen,
            problem: nil,
            raw: line
        )
    }

    private static func render(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        ) {
            return String(decoding: data, as: UTF8.self)
        }
        return String(describing: value)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return try? Date(string, strategy: .iso8601)
    }
}
