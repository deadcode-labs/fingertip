//
//  AppUpdater.swift
//  Fingertip
//
//  Self-updating through Sparkle. The feed and the public EdDSA key are in
//  App/Info.plist; scripts/release-dmg.sh signs each DMG and writes the appcast.
//

import AppKit
import Sparkle

final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController!

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        // A menu-bar app is never frontmost; without this the update window opens behind.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // A menu-bar app has no Dock icon to badge: Sparkle asks background apps to opt in
    // so a scheduled update is shown without stealing focus.
    var supportsGentleScheduledUpdateReminders: Bool { true }
}
