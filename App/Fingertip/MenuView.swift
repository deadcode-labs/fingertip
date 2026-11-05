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
            Text("⚠︎ Modo dios activo: apps bloqueadas permitidas")
            Divider()
        }

        Button("Pruebas…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "tests")
        }

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
