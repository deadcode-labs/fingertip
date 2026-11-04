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
        case general, security, captures, jev

        var id: Self { self }

        var title: String {
            switch self {
            case .general: "General"
            case .security: "Seguridad"
            case .captures: "Capturas"
            case .jev: "Jev"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .security: "lock.shield"
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
                case .security: SecurityPane(settings: $settings, apiKey: apiKey, saveError: saveError)
                case .captures: CapturesPane(settings: $settings, saveError: saveError)
                case .jev: JevPane(apiKey: $apiKey)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 680, height: 520)
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
    @AppStorage(ClaudeMCPInstaller.unrestrictedKey) private var unrestricted = false

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
        let unrestricted = unrestricted
        Task {
            // `claude mcp add` blocks on a subprocess; keep it off the main actor.
            let result = await Task.detached { ClaudeMCPInstaller.install(apiKey: key, unrestricted: unrestricted) }.value
            installResult = result
            installing = false
        }
    }
}

// MARK: - Security

private struct SecurityPane: View {
    @Binding var settings: FingertipSettings
    let apiKey: String
    let saveError: String?
    @AppStorage(ClaudeMCPInstaller.unrestrictedKey) private var unrestricted = false
    @State private var confirmingUnrestricted = false
    @State private var installing = false
    @State private var installError: String?
    @State private var addingApp = false
    @State private var addError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Modo dios: permitir todas las apps", isOn: Binding(
                    get: { unrestricted },
                    set: { on in
                        if on {
                            confirmingUnrestricted = true
                        } else {
                            setUnrestricted(false)
                        }
                    }
                ))
                .disabled(installing)
                if unrestricted {
                    Label("Activo en todas las sesiones de Claude Code hasta que lo apagues.",
                          systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                if let installError {
                    Label(installError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Modo dios")
            } footer: {
                Text("Libera todas las apps de esta lista, Fingertip incluida. Cambiarlo vuelve a registrar el servidor; después reconectá con `/mcp`.")
            }
            .alert("¿Activar el modo dios?", isPresented: $confirmingUnrestricted) {
                Button("Activar", role: .destructive) { setUnrestricted(true) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(Self.unrestrictedWarning)
            }

            Section {
                Text("El MCP no maneja estas apps: escribir en ellas puede correr comandos o exponer secretos. Prendé una para permitirla. Vale desde el próximo uso, sin reconectar. Las que no tenés instaladas no aparecen y siguen bloqueadas.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apps bloqueadas")
            }

            ForEach(BlockedApps.builtIn) { group in
                let installed = group.bundleIDs.filter { BlockedAppRow.isInstalled($0) }
                if !installed.isEmpty {
                    Section(group.name) {
                        ForEach(installed, id: \.self) { id in
                            BlockedAppRow(bundleID: id, isAllowed: allowedBinding(id))
                        }
                    }
                    .disabled(unrestricted)
                }
            }

            Section {
                LabeledContent {
                    Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                } label: {
                    BlockedAppRow.Label(bundleID: BlockedApps.fingertip)
                }
                .help("Sus ajustes tienen estos switches: solo el modo dios la libera.")
            } header: {
                Text("Fingertip")
            } footer: {
                Text("No se puede permitir sola: desde estos ajustes se libera todo lo demás. Solo el modo dios la libera.")
            }

            Section {
                ForEach(settings.extraBlockedApps, id: \.self) { id in
                    HStack {
                        BlockedAppRow(bundleID: id, isAllowed: allowedBinding(id))
                        Button {
                            settings.extraBlockedAppIDs = settings.extraBlockedApps.filter { $0 != id }
                            settings.unblockedAppIDs = settings.unblockedApps.filter { $0 != id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Quitar de la lista")
                    }
                }
                .disabled(unrestricted)
                HStack {
                    if let addError {
                        Text(addError).foregroundStyle(.orange).font(.callout)
                    }
                    Spacer()
                    Button("Agregar app…") { addingApp = true }
                }
            } header: {
                Text("Agregadas por vos")
            } footer: {
                Text("Elegí una app para bloquearla igual que las de arriba.")
            }
            .fileImporter(isPresented: $addingApp, allowedContentTypes: [.application]) { result in
                if case .success(let url) = result { add(url) }
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func allowedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { settings.unblockedApps.contains(id) },
            set: { allowed in
                var unblocked = settings.unblockedApps.filter { $0 != id }
                if allowed { unblocked.append(id) }
                settings.unblockedAppIDs = unblocked
            }
        )
    }

    private func add(_ url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier?.lowercased() else {
            addError = "No pude leer el bundle id de \(url.lastPathComponent)."
            return
        }
        addError = nil
        let listed = BlockedApps.builtIn.flatMap(\.bundleIDs) + [BlockedApps.fingertip] + settings.extraBlockedApps
        guard !listed.contains(id) else {
            // Already listed: adding it means the user wants it blocked again.
            settings.unblockedAppIDs = settings.unblockedApps.filter { $0 != id }
            return
        }
        settings.extraBlockedAppIDs = settings.extraBlockedApps + [id]
    }

    private static let unrestrictedWarning = """
    Claude va a poder conectarse y escribir en todas las apps bloqueadas: Terminal, iTerm y otras terminales; VS Code, Cursor, Zed, JetBrains y otros editores con terminal; las apps de Claude, Codex y ChatGPT; Script Editor, Automator, Atajos, Raycast y Alfred; esta misma app; Ajustes del Sistema; Acceso a Llaveros, Contraseñas, 1Password y otros gestores; y las que agregaste vos.

    Qué implica:
    • Todo lo que fingertip lee de la pantalla le llega a Claude como texto. Una instrucción escondida en una web, un mail o un documento puede llevarlo a abrir una terminal y correr un comando con tus permisos: borrar archivos, subir tus datos, instalar algo.
    • Las contraseñas, tokens y claves que se vean en pantalla pasan a la conversación.
    • Puede cambiar permisos de privacidad y seguridad en Ajustes del Sistema.
    • Puede darle órdenes a otros agentes, que actúan con sus propios permisos.
    • Vale para todos tus proyectos y sesiones de Claude Code, no solo para la tarea de ahora, hasta que lo apagues.

    Si solo necesitás una app, es más seguro desbloquear esa sola en esta lista.
    """

    /// Re-registers the server with the new value; on failure the switch goes back,
    /// so it never shows a mode the registration does not have.
    private func setUnrestricted(_ on: Bool) {
        let previous = unrestricted
        unrestricted = on
        installing = true
        let key = apiKey
        Task {
            // `claude mcp add` blocks on a subprocess; keep it off the main actor.
            let result = await Task.detached { ClaudeMCPInstaller.install(apiKey: key, unrestricted: on) }.value
            installing = false
            installError = result.succeeded ? nil : result.message
            if !result.succeeded { unrestricted = previous }
        }
    }
}

/// One app of the block list: icon and name when it is installed, the bundle id otherwise.
private struct BlockedAppRow: View {
    let bundleID: String
    @Binding var isAllowed: Bool

    var body: some View {
        Toggle(isOn: $isAllowed) { Label(bundleID: bundleID) }
            .accessibilityLabel("Permitir \(bundleID)")
    }

    static func isInstalled(_ id: String) -> Bool {
        id == BlockedApps.jetBrainsPrefix || NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    struct Label: View {
        let bundleID: String

        var body: some View {
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            HStack(spacing: 8) {
                if let url {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.dashed").frame(width: 20, height: 20)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name(url))
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private func name(_ url: URL?) -> String {
            if bundleID == BlockedApps.jetBrainsPrefix { return "IDEs de JetBrains (todos)" }
            guard let url else { return bundleID }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
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
