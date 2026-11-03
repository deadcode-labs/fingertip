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
    }
}
