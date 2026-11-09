//
//  CrashReporting.swift
//  FingertipCore
//
//  Crash reports through Sentry, for the app and `fingertip-mcp`. On unless the
//  user turns it off in Settings, and crashes only: no sessions, breadcrumbs,
//  performance, hangs or captured errors. A crash is written to disk when it
//  happens and sent on the process's next launch, after `beforeSend` strips
//  what could identify the user or carry screen contents.
//

import Foundation
import Sentry

public enum CrashReporting {
    /// Empty until a Sentry project exists; while empty, nothing starts.
    static let dsn = ""

    /// Read once per process: turning it on or off takes a relaunch of the app and `/mcp` for the MCP.
    public static func start(release: String) {
        guard !dsn.isEmpty, FingertipSettings.load().crashReportsEnabled else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = release
            options.sendDefaultPii = false
            options.enableCrashHandler = true
            options.enableAutoSessionTracking = false
            options.maxBreadcrumbs = 0
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAutoPerformanceTracing = false
            options.enableNetworkTracking = false
            options.enableFileIOTracing = false
            options.enableCaptureFailedRequests = false
            options.enableAppHangTracking = false
            options.enableSwizzling = false
            options.beforeSend = { event in scrub(event) }
        }
    }

    /// Drops anything that is not a crash, and from a crash anything beyond the stack,
    /// the exception, and the OS, device model and app version.
    nonisolated private static func scrub(_ event: Event) -> Event? {
        guard event.level == .fatal else { return nil }
        event.serverName = nil
        event.user = nil
        event.breadcrumbs = nil
        event.extra = nil
        event.message = nil
        event.request = nil
        event.context = event.context?
            .filter { ["os", "device", "app"].contains($0.key) }
            // `device_app_hash` is stable per Mac and would link one user's crashes together.
            .mapValues { $0.filter { !["name", "locale", "device_app_hash"].contains($0.key) } }

        // Paths under the home folder carry the user name: binaries built in DerivedData,
        // and source paths in Swift's fatal error messages.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tidy = { (text: String?) in text?.replacing(home, with: "~") }
        for exception in event.exceptions ?? [] {
            exception.value = tidy(exception.value) ?? ""
            exception.stacktrace?.frames.forEach { $0.package = tidy($0.package) }
        }
        for thread in event.threads ?? [] {
            thread.stacktrace?.frames.forEach { $0.package = tidy($0.package) }
        }
        for image in event.debugMeta ?? [] {
            image.codeFile = tidy(image.codeFile)
        }
        return event
    }
}
