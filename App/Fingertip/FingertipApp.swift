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
    }

    var body: some Scene {
        MenuBarExtra("Fingertip", systemImage: "hand.tap") {
            MenuView()
        }

        Settings {
            SettingsView()
        }

        Window("Configuración inicial", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(
            UserDefaults.standard.bool(forKey: OnboardingView.completedKey) ? .suppressed : .presented
        )

        Window("Pruebas", id: "tests") {
            TestsView()
        }
        .defaultSize(width: 1100, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}
