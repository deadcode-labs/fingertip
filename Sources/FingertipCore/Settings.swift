//
//  Settings.swift
//  FingertipCore
//
//  Settings shared by the Fingertip menu-bar app and `fingertip-mcp`, which
//  does the work. A JSON file in Application Support
//  rather than UserDefaults: there is no app group, and each bundle id has its
//  own defaults domain, so UserDefaults is not shared across processes.
//

import Foundation

public nonisolated struct FingertipSettings: Codable, Equatable, Sendable {
    /// Where Jev runs go (JSONL + a folder of screenshots per run). `nil` uses
    /// `~/Library/Application Support/flowforge-jev/runs`.
    public var runsDirectory: URL?
    /// Where the MCP `screenshot` tool saves the full PNG. `nil` uses
    /// `$TMPDIR/fingertip-mcp`, which macOS cleans up on its own.
    public var screenshotsDirectory: URL?
    /// Where the MCP `stop_recording` leaves the `.mov`. `nil` uses `$TMPDIR/fingertip-mcp/recordings`.
    public var recordingsDirectory: URL?
    /// Whether the MCP `bring_to_front` tool may run. It activates the app and can switch
    /// the desktop the user is looking at, so it is off until the user turns it on. Optional
    /// so a settings file written before it decodes; `nil` is off.
    public var allowsBringToFront: Bool?
    /// Entries of `BlockedApps.builtIn` or `extraBlockedApps` the user unblocked, lowercased.
    /// Optional so an older settings file decodes; read through `unblockedApps`.
    public var unblockedAppIDs: [String]?
    /// Bundle ids the user added to the block list, lowercased.
    public var extraBlockedAppIDs: [String]?
    /// Whether the app and the MCP send crash reports to Sentry. Optional so an older
    /// settings file decodes; `nil` is off.
    public var sendsCrashReports: Bool?

    public nonisolated init(runsDirectory: URL? = nil, screenshotsDirectory: URL? = nil, recordingsDirectory: URL? = nil) {
        self.runsDirectory = runsDirectory
        self.screenshotsDirectory = screenshotsDirectory
        self.recordingsDirectory = recordingsDirectory
    }

    public var bringToFrontEnabled: Bool { allowsBringToFront ?? false }
    public var unblockedApps: [String] { unblockedAppIDs ?? [] }
    public var extraBlockedApps: [String] { extraBlockedAppIDs ?? [] }
    public var crashReportsEnabled: Bool { sendsCrashReports ?? false }

    /// Named after the removed Jev app, where runs were first logged; kept so earlier runs stay
    /// in the same folder.
    public static let defaultRunsDirectory = URL.applicationSupportDirectory
        .appending(path: "flowforge-jev/runs", directoryHint: .isDirectory)

    public static let defaultScreenshotsDirectory = URL.temporaryDirectory
        .appending(path: "fingertip-mcp", directoryHint: .isDirectory)

    public static let defaultRecordingsDirectory = defaultScreenshotsDirectory
        .appending(path: "recordings", directoryHint: .isDirectory)

    public var effectiveRecordingsDirectory: URL {
        recordingsDirectory ?? Self.defaultRecordingsDirectory
    }

    public var effectiveRunsDirectory: URL {
        runsDirectory ?? Self.defaultRunsDirectory
    }

    public var effectiveScreenshotsDirectory: URL {
        screenshotsDirectory ?? Self.defaultScreenshotsDirectory
    }

    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "fingertip/settings.json")
    }

    /// Read on every use, not cached: the app may change it while the MCP runs.
    public static func load() -> FingertipSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(FingertipSettings.self, from: data)
        else { return FingertipSettings() }
        return settings
    }

    public func save() throws {
        let directory = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.fileURL, options: .atomic)
    }
}
