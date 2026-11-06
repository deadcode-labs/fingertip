//
//  MenuView.swift
//  Fingertip
//

import SwiftUI

struct MenuView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(ClaudeMCPInstaller.unrestrictedKey) private var unrestricted = false

    var body: some View {
        if unrestricted {
            Text("⚠︎ God mode on: blocked apps allowed")
            Divider()
        }

        Button("Tests…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "tests")
        }

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Check for Updates…") {
            AppUpdater.shared.checkForUpdates()
        }

        Button("Setup…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
        }

        Divider()

        Button("Quit Fingertip") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
