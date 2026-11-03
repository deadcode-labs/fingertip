//
//  OnboardingView.swift
//  Fingertip
//
//  The first-launch window: a few steps that check what fingertip needs and
//  fix what can be fixed from here (install sim-use, register the MCP). It
//  opens by itself until finished once; the menu reopens it.
//

import AppKit
import SwiftUI

struct OnboardingView: View {
    static let completedKey = "onboardingCompleted"

    private enum Step: Int, CaseIterable {
        case welcome, simulator, jev, claude, mac, done
    }

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = Step.welcome
    @State private var usesSimulator = true
    @State private var apiKey = KeychainStore.load() ?? ""

    @State private var runtimes: SetupService.Check?
    @State private var simUse: SetupService.Check?
    @State private var installingSimUse = false
    @State private var registration: SetupService.Check?
    @State private var registering = false

    var body: some View {
        VStack(spacing: 0) {
            StepDots(count: Step.allCases.count, current: step.rawValue)
                .padding(.top, 20)

            Group {
                switch step {
                case .welcome: welcome
                case .simulator: simulator
                case .jev: jev
                case .claude: claude
                case .mac: mac
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()
            footer.padding(16)
        }
        .frame(width: 560, height: 460)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Steps

    private var welcome: some View {
        StepPage(symbol: "hand.tap", title: "Bienvenido a Fingertip") {
            Text("Fingertip deja que Claude Code vea y maneje un simulador de iOS o una app de macOS: lee la pantalla, toca, escribe y scrollea.")
            Text("En los próximos pasos verificamos que esté todo listo para usarlo.")
                .foregroundStyle(.secondary)
        }
    }

    private var simulator: some View {
        StepPage(symbol: "iphone", title: "Simulador de iOS") {
            Toggle("Voy a probar apps en el simulador de iOS", isOn: $usesSimulator)
                .toggleStyle(.switch)

            if usesSimulator {
                CheckRow(title: "Xcode y runtimes de iOS", check: runtimes, running: runtimes == nil)
                CheckRow(title: "sim-use", check: simUse, running: simUse == nil || installingSimUse) {
                    if simUse?.passed == false {
                        Button("Instalar sim-use") { installSimUse() }
                            .disabled(installingSimUse)
                    }
                }
                Text("sim-use lee la pantalla del simulador y le manda los toques. Se instala con Homebrew: `\(SetupService.simUseInstallCommand)`")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("Solo vas a usar apps de macOS: no hace falta nada de esto. Podés volver a este paso desde el menú.")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: usesSimulator) {
            guard usesSimulator, runtimes == nil else { return }
            async let checkedRuntimes = Task.detached { SetupService.simulatorRuntimes() }.value
            async let checkedSimUse = Task.detached { SetupService.simUse() }.value
            (runtimes, simUse) = await (checkedRuntimes, checkedSimUse)
        }
    }

    private var jev: some View {
        StepPage(symbol: "sparkles", title: "Jev (opcional)") {
            Text("Normalmente Claude decide cada toque. Con `run_instruction`, Claude le delega una instrucción entera a Jev, que elige los pasos por su cuenta: menos idas y vueltas, pero necesita una clave de API de TypeSafe.")
            Text("Sin clave, todas las demás tools funcionan igual. Si no tenés una, seguí de largo; podés cargarla después en Ajustes → Jev.")
                .foregroundStyle(.secondary)
            SecureField("TYPESAFE_API_KEY", text: $apiKey, prompt: Text("Pegá tu clave"))
                .textFieldStyle(.roundedBorder)
            Text("Se guarda en el Llavero y se le pasa a Claude Code al registrar el MCP en el paso siguiente.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onChange(of: apiKey) { _, new in
            KeychainStore.save(new)
            registration = nil // the registration check depends on whether there is a key
        }
    }

    private var claude: some View {
        StepPage(symbol: "terminal", title: "Claude Code") {
            Text("Fingertip se usa desde Claude Code como un servidor MCP. Esta app trae el servidor adentro y lo registra para todos tus proyectos.")
            CheckRow(title: "Registro en Claude Code", check: registration, running: registration == nil || registering) {
                if registration != nil {
                    Button(registration?.passed == true ? "Volver a registrar" : "Registrar") { register() }
                        .disabled(registering)
                }
            }
            Text("Después de registrarlo, reconectá en Claude Code con `/mcp`.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task {
            guard registration == nil else { return }
            let expectsKey = !apiKey.isEmpty
            registration = await Task.detached { SetupService.claudeRegistration(expectsJevKey: expectsKey) }.value
        }
    }

    private var mac: some View {
        StepPage(symbol: "macwindow", title: "Apps de macOS") {
            Text("Para manejar apps de macOS hacen falta dos permisos. macOS no se los da a Fingertip sino a la app desde la que corrés Claude Code: tu terminal o Claude.")
            PermissionRow(
                title: "Accesibilidad",
                detail: "Obligatorio: leer la pantalla y actuar.",
                pane: "Privacy_Accessibility"
            )
            PermissionRow(
                title: "Grabación de pantalla",
                detail: "Para screenshots y grabaciones.",
                pane: "Privacy_ScreenCapture"
            )
            Text("Si falta alguno, la primera vez que fingertip se conecte a una app macOS lo va a pedir.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        StepPage(symbol: "checkmark.seal", title: "Listo") {
            Text("Fingertip vive en la barra de menú. Desde ahí abrís los ajustes o volvés a este asistente.")
            Text("En Claude Code, probá: «leé la pantalla del simulador».")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Atrás") { move(by: -1) }
            }
            Spacer()
            if step == .done {
                Button("Empezar") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continuar") { move(by: 1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func move(by offset: Int) {
        step = Step(rawValue: step.rawValue + offset) ?? step
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismissWindow()
    }

    private func installSimUse() {
        installingSimUse = true
        Task {
            simUse = await Task.detached { SetupService.installSimUse() }.value
            installingSimUse = false
        }
    }

    private func register() {
        registering = true
        let key = apiKey
        Task {
            // `claude mcp add` blocks on a subprocess; keep it off the main actor.
            let installed = await Task.detached { ClaudeMCPInstaller.install(apiKey: key) }.value
            registration = installed.succeeded
                ? await Task.detached { SetupService.claudeRegistration(expectsJevKey: !key.isEmpty) }.value
                : SetupService.Check(passed: false, detail: installed.message)
            registering = false
        }
    }
}

// MARK: - Pieces

private struct StepPage<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.title2.weight(.semibold))
            content
        }
    }
}

private struct StepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

private struct CheckRow<Action: View>: View {
    let title: String
    let check: SetupService.Check?
    let running: Bool
    @ViewBuilder var action: Action

    init(title: String, check: SetupService.Check?, running: Bool, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.check = check
        self.running = running
        self.action = action()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if running {
                    ProgressView().controlSize(.small)
                } else if check?.passed == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let check, !running {
                    Text(check.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            action
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let pane: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abrir Ajustes") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
