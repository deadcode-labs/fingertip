//
//  SettingsView.swift
//  Fingertip
//
//  The settings window: a sidebar of sections, each a grouped form.
//

import AppKit
import FingertipCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, captures, jev

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .captures: "Capturas"
            case .jev: "Jev"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .captures: "camera.viewfinder"
            case .jev: "sparkles"
            }
        }
    }

    @State private var selection: Pane? = .general
    @State private var settings = FingertipSettings.load()
    @State private var apiKey = KeychainStore.load() ?? ""
    @State private var saveError: String?

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let pane = selection ?? .general
            Group {
                switch pane {
                case .general: GeneralPane(settings: $settings, apiKey: apiKey, saveError: saveError)
                case .captures: CapturesPane(settings: $settings, saveError: saveError)
                case .jev: JevPane(apiKey: $apiKey)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 680, height: 440)
        .onChange(of: settings) { _, new in
            do {
                try new.save()
                saveError = nil
            } catch {
                saveError = "No pude guardar los ajustes: \(error.localizedDescription)"
            }
        }
        .onChange(of: apiKey) { _, new in KeychainStore.save(new) }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Binding var settings: FingertipSettings
    let apiKey: String
    let saveError: String?
    @State private var installResult: ClaudeMCPInstaller.Result?
    @State private var installing = false

    private var mcpPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/fingertip-mcp").path
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Servidor") {
                    Text(abbreviated(mcpPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Registro") {
                    Button(installing ? "Registrando…" : "Instalar / actualizar") { install() }
                        .disabled(installing)
                }
                if let installResult {
                    Label(installResult.message,
                          systemImage: installResult.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(installResult.succeeded ? .green : .orange)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("Registra fingertip en Claude Code para todos tus proyectos. Después reconectá con `/mcp`.")
            }

            Section("Overlay") {
                LabeledContent("Puntero y estado") {
                    Text("Se muestran mientras esta app esté abierta")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Permitir traer ventanas al frente", isOn: Binding(
                    get: { settings.bringToFrontEnabled },
                    set: { settings.allowsBringToFront = $0 }
                ))
            } header: {
                Text("Ventanas")
            } footer: {
                Text("Habilita `bring_to_front`: activa la app y, si la ventana está en otro escritorio, cambia a ese escritorio. Mueve lo que estás viendo. El MCP lo lee en cada uso: no hace falta reconectar.")
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func install() {
        installing = true
        let key = apiKey
        Task {
            // `claude mcp add` blocks on a subprocess; keep it off the main actor.
            let result = await Task.detached { ClaudeMCPInstaller.install(apiKey: key) }.value
            installResult = result
            installing = false
        }
    }
}

// MARK: - Captures

private struct CapturesPane: View {
    @Binding var settings: FingertipSettings
    let saveError: String?

    var body: some View {
        Form {
            Section {
                FolderRow(
                    title: "Carpeta",
                    url: settings.effectiveScreenshotsDirectory,
                    isCustom: settings.screenshotsDirectory != nil,
                    choose: { settings.screenshotsDirectory = $0 },
                    reset: { settings.screenshotsDirectory = nil }
                )
            } header: {
                Text("Screenshots del MCP")
            } footer: {
                Text("Cada `screenshot` guarda acá el PNG completo. Por defecto es una carpeta temporal que macOS limpia sola.")
            }

            Section {
                FolderRow(
                    title: "Carpeta",
                    url: settings.effectiveRecordingsDirectory,
                    isCustom: settings.recordingsDirectory != nil,
                    choose: { settings.recordingsDirectory = $0 },
                    reset: { settings.recordingsDirectory = nil }
                )
            } header: {
                Text("Grabaciones del MCP")
            } footer: {
                Text("Cada `start_recording` / `stop_recording` deja acá un .mov. Por defecto es una carpeta temporal que macOS limpia sola.")
            }

            Section {
                FolderRow(
                    title: "Carpeta",
                    url: settings.effectiveRunsDirectory,
                    isCustom: settings.runsDirectory != nil,
                    choose: { settings.runsDirectory = $0 },
                    reset: { settings.runsDirectory = nil }
                )
            } header: {
                Text("Runs de Jev")
            } footer: {
                Text("Cada run guarda un JSONL con los pasos y una carpeta con las capturas.")
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct FolderRow: View {
    let title: String
    let url: URL
    let isCustom: Bool
    let choose: (URL) -> Void
    let reset: () -> Void

    @State private var picking = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(abbreviated(url.path))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(url.path)
                Spacer(minLength: 0)
            }
        }
        HStack {
            Spacer()
            if isCustom {
                Button("Usar la predeterminada", action: reset)
            }
            Button("Mostrar en Finder") { reveal() }
            Button("Elegir…") { picking = true }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { choose(folder) }
        }
    }

    private func reveal() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Jev

private struct JevPane: View {
    @Binding var apiKey: String

    var body: some View {
        Form {
            Section {
                SecureField("TYPESAFE_API_KEY", text: $apiKey, prompt: Text("Pegá tu clave"))
            } header: {
                Text("Clave de API")
            } footer: {
                Text("La usa `run_instruction`. Se guarda en el Llavero y se pasa al registrar el MCP: si la cambiás, volvé a instalar desde General.")
            }
        }
    }
}

private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
