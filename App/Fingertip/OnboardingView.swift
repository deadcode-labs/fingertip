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
        StepPage(symbol: "hand.tap", title: "Welcome to Fingertip") {
            Text("Fingertip lets Claude Code see and drive an iOS simulator or a macOS app: it reads the screen, taps, types and scrolls.")
            Text("The next steps check that everything is ready to use it.")
                .foregroundStyle(.secondary)
        }
    }

    private var simulator: some View {
        StepPage(symbol: "iphone", title: "iOS Simulator") {
            Toggle("I’ll test apps in the iOS simulator", isOn: $usesSimulator)
                .toggleStyle(.switch)

            if usesSimulator {
                CheckRow(title: "Xcode and iOS runtimes", check: runtimes, running: runtimes == nil)
                CheckRow(title: "sim-use", check: simUse, running: simUse == nil || installingSimUse) {
                    if simUse?.passed == false {
                        Button("Install sim-use") { installSimUse() }
                            .disabled(installingSimUse)
                    }
                }
                Text("sim-use reads the simulator’s screen and sends it the taps. It installs with Homebrew: `\(SetupService.simUseInstallCommand)`")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text("You’ll only use macOS apps, so none of this is needed. You can come back to this step from the menu.")
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
        StepPage(symbol: "sparkles", title: "Jev (optional)") {
            Text("Normally Claude decides every tap. With `run_instruction`, Claude hands a whole instruction to Jev, which picks the steps on its own: fewer round trips, but it needs a TypeSafe API key.")
            Text("Without a key, every other tool works the same. If you don’t have one, skip this step; you can add it later in Settings → Jev.")
                .foregroundStyle(.secondary)
            SecureField("TYPESAFE_API_KEY", text: $apiKey, prompt: Text("Paste your key"))
                .textFieldStyle(.roundedBorder)
            Text("It is stored in the Keychain and passed to Claude Code when the MCP is registered in the next step.")
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
            Text("Fingertip is used from Claude Code as an MCP server. This app ships the server inside and registers it for all your projects.")
            CheckRow(title: "Registration in Claude Code", check: registration, running: registration == nil || registering) {
                if registration != nil {
                    Button(registration?.passed == true ? "Register Again" : "Register") { register() }
                        .disabled(registering)
                }
            }
            Text("After registering it, reconnect in Claude Code with `/mcp`.")
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
        StepPage(symbol: "macwindow", title: "macOS Apps") {
            Text("Driving macOS apps needs two permissions. macOS grants them not to Fingertip but to the app you run Claude Code from: your terminal or Claude.")
            PermissionRow(
                title: "Accessibility",
                detail: "Required: reading the screen and acting on it.",
                pane: "Privacy_Accessibility"
            )
            PermissionRow(
                title: "Screen Recording",
                detail: "For screenshots and recordings.",
                pane: "Privacy_ScreenCapture"
            )
            Text("If one is missing, fingertip asks for it the first time it connects to a macOS app.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var done: some View {
        StepPage(symbol: "checkmark.seal", title: "All Set") {
            Text("Fingertip lives in the menu bar. From there you open the settings or come back to this assistant.")
            Text("In Claude Code, try: “read the simulator’s screen”.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(by: -1) }
            }
            Spacer()
            if step == .done {
                Button("Get Started") { finish() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { move(by: 1) }
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
        let unrestricted = UserDefaults.standard.bool(forKey: ClaudeMCPInstaller.unrestrictedKey)
        Task {
            // `claude mcp add` blocks on a subprocess; keep it off the main actor.
            let installed = await Task.detached { ClaudeMCPInstaller.install(apiKey: key, unrestricted: unrestricted) }.value
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
    let title: LocalizedStringKey
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
    let title: LocalizedStringKey
    let check: SetupService.Check?
    let running: Bool
    @ViewBuilder var action: Action

    init(title: LocalizedStringKey, check: SetupService.Check?, running: Bool, @ViewBuilder action: () -> Action = { EmptyView() }) {
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
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let pane: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
