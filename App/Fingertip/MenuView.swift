//
//  MenuView.swift
//  Fingertip
//

import SwiftUI

struct MenuView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Ajustes…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Salir") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
