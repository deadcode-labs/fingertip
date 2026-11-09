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
            case .general: String(localized: "General")
            case .security: String(localized: "Security")
            case .captures: String(localized: "Captures")
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
                saveError = String(localized: "Couldn’t save the settings: \(error.localizedDescription)")
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
    @State private var checksForUpdates = AppUpdater.shared.automaticallyChecksForUpdates

    private var mcpPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/fingertip-mcp").path
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Server") {
                    Text(abbreviated(mcpPath))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Registration") {
                    Button(installing ? "Registering…" : "Install / Update") { install() }
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
                Text("Registers fingertip in Claude Code for all your projects. Then reconnect with `/mcp`.")
            }

            Section("Overlay") {
                LabeledContent("Pointer and status") {
                    Text("Shown while this app is running")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Allow bringing windows to the front", isOn: Binding(
                    get: { settings.bringToFrontEnabled },
                    set: { settings.allowsBringToFront = $0 }
                ))
            } header: {
                Text("Windows")
            } footer: {
                Text("Enables `bring_to_front`: it activates the app and, if the window is on another desktop, switches to that desktop. It changes what you are looking at. The MCP reads this on every use, so there is no need to reconnect.")
            }

            Section {
                Toggle("Check for updates automatically", isOn: $checksForUpdates)
                    .onChange(of: checksForUpdates) { _, new in
                        AppUpdater.shared.automaticallyChecksForUpdates = new
                    }
                LabeledContent("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")") {
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updating the app also updates the `fingertip-mcp` it ships with: reconnect with `/mcp`.")
            }

            Section {
                Toggle("Send crash reports", isOn: Binding(
                    get: { settings.crashReportsEnabled },
                    set: { settings.sendsCrashReports = $0 }
                ))
            } header: {
                Text("Privacy")
            } footer: {
                Text("When the app or the MCP crashes, sends the stack trace, macOS version and Mac model to Sentry on the next launch. Nothing from your screen, what was typed, your user name or your Mac’s name. Takes effect after relaunching the app and reconnecting with `/mcp`.")
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
                Toggle("God mode: allow all apps", isOn: Binding(
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
                    Label("On in every Claude Code session until you turn it off.",
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
                Text("God Mode")
            } footer: {
                Text("Unblocks every app on this list, Fingertip included. Changing it registers the server again; then reconnect with `/mcp`.")
            }
            .alert("Turn on god mode?", isPresented: $confirmingUnrestricted) {
                Button("Turn On", role: .destructive) { setUnrestricted(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Self.unrestrictedWarning)
            }

            Section {
                Text("The MCP doesn’t drive these apps: typing into them can run commands or expose secrets. Turn one on to allow it and reconnect with `/mcp`: the MCP reads the allowed apps only at launch, so an injected instruction can’t unblock them mid-session by editing the settings. Apps you don’t have installed don’t appear and stay blocked.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Blocked Apps")
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
                .help("Its settings hold these switches: only god mode unblocks it.")
            } header: {
                Text("Fingertip")
            } footer: {
                Text("It can’t be allowed on its own: these settings unblock everything else. Only god mode unblocks it.")
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
                        .help("Remove from the list")
                    }
                }
                .disabled(unrestricted)
                HStack {
                    if let addError {
                        Text(addError).foregroundStyle(.orange).font(.callout)
                    }
                    Spacer()
                    Button("Add App…") { addingApp = true }
                }
            } header: {
                Text("Added by You")
            } footer: {
                Text("Choose an app to block it like the ones above. Blocking takes effect on the next connection to that app, without reconnecting the MCP; removing it from the list, like allowing, needs `/mcp`.")
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
            addError = String(localized: "Couldn’t read the bundle ID of \(url.lastPathComponent).")
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

    private static let unrestrictedWarning = String(localized: """
    Claude will be able to connect to and type into every blocked app: Terminal, iTerm and other terminals; VS Code, Cursor, Zed, JetBrains and other editors with a terminal; the Claude, Codex and ChatGPT apps; Script Editor, Automator, Shortcuts, Raycast and Alfred; this app itself; System Settings; Keychain Access, Passwords, 1Password and other password managers; and the apps you added.

    What this means:
    • Everything fingertip reads from the screen reaches Claude as text. An instruction hidden in a web page, an email or a document can lead it to open a terminal and run a command with your permissions: delete files, upload your data, install something.
    • Passwords, tokens and keys visible on screen end up in the conversation.
    • It can change privacy and security permissions in System Settings.
    • It can give orders to other agents, which act with their own permissions.
    • It applies to all your projects and Claude Code sessions, not just the current task, until you turn it off.

    If you only need one app, it is safer to unblock just that one on this list.
    """)

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
            .accessibilityLabel("Allow \(bundleID)")
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
            if bundleID == BlockedApps.jetBrainsPrefix { return String(localized: "JetBrains IDEs (all)") }
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
                    title: "Folder",
                    url: settings.effectiveScreenshotsDirectory,
                    isCustom: settings.screenshotsDirectory != nil,
                    choose: { settings.screenshotsDirectory = $0 },
                    reset: { settings.screenshotsDirectory = nil }
                )
            } header: {
                Text("MCP Screenshots")
            } footer: {
                Text("Each `screenshot` saves the full PNG here. By default it is a temporary folder that macOS cleans up on its own.")
            }

            Section {
                FolderRow(
                    title: "Folder",
                    url: settings.effectiveRecordingsDirectory,
                    isCustom: settings.recordingsDirectory != nil,
                    choose: { settings.recordingsDirectory = $0 },
                    reset: { settings.recordingsDirectory = nil }
                )
            } header: {
                Text("MCP Recordings")
            } footer: {
                Text("Each `start_recording` / `stop_recording` leaves a .mov here. By default it is a temporary folder that macOS cleans up on its own.")
            }

            Section {
                FolderRow(
                    title: "Folder",
                    url: settings.effectiveRunsDirectory,
                    isCustom: settings.runsDirectory != nil,
                    choose: { settings.runsDirectory = $0 },
                    reset: { settings.runsDirectory = nil }
                )
            } header: {
                Text("Jev Runs")
            } footer: {
                Text("Each run saves a JSONL file with the steps and a folder with the screenshots.")
            }

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct FolderRow: View {
    let title: LocalizedStringKey
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
                Button("Use Default", action: reset)
            }
            Button("Show in Finder") { reveal() }
            Button("Choose…") { picking = true }
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
                SecureField("TYPESAFE_API_KEY", text: $apiKey, prompt: Text("Paste your key"))
            } header: {
                Text("API Key")
            } footer: {
                Text("Used by `run_instruction`. It is stored in the Keychain and passed along when the MCP is registered: if you change it, install again from General.")
            }
        }
    }
}

private func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
