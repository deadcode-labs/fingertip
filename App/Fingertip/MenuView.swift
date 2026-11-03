//
//  MenuView.swift
//  Fingertip
//

import SwiftUI

struct MenuView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Ajustes…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Configuración inicial…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "onboarding")
        }

        Divider()

        Button("Salir") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
