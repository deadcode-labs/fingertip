//
//  FingertipApp.swift
//  Fingertip
//

import FingertipCore
import SwiftUI

@main
struct FingertipApp: App {
    init() {
        Task { await OverlayBeaconServer.shared.start() }
        _ = AppUpdater.shared
        CrashReporting.start(release: "fingertip@" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""))
    }

    var body: some Scene {
        MenuBarExtra("Fingertip", systemImage: "hand.tap") {
            MenuView()
        }

        Settings {
            SettingsView()
        }

        Window("Setup", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(
            UserDefaults.standard.bool(forKey: OnboardingView.completedKey) ? .suppressed : .presented
        )

        Window("Tests", id: "tests") {
            TestsView()
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}
