//
//  SetupService.swift
//  Fingertip
//
//  The checks behind the first-launch onboarding: Xcode's simulator runtimes,
//  sim-use, and fingertip's registration in Claude Code. Every call blocks on
//  a subprocess, so callers run it off the main actor.
//

import FingertipCore
import Foundation

nonisolated enum SetupService {
    struct Check: Sendable, Equatable {
        let passed: Bool
        let detail: String
    }

    static let simUseInstallCommand = "brew tap lycorp-jp/tap && brew install lycorp-jp/tap/sim-use"

    static var bundledMCPPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/fingertip-mcp").path
    }

    // MARK: - iOS Simulator

    static func simulatorRuntimes() -> Check {
        let (status, output) = ClaudeMCPInstaller.run(
            URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl", "list", "runtimes", "--json"]
        )
        guard status == 0 else {
            return Check(passed: false, detail: String(localized: "`xcrun simctl` isn’t responding: install Xcode and open it once."))
        }

        struct Runtimes: Decodable {
            struct Runtime: Decodable {
                let name: String
                let isAvailable: Bool
            }
            let runtimes: [Runtime]
        }
        let names = (try? JSONDecoder().decode(Runtimes.self, from: Data(output.utf8)))?
            .runtimes
            .filter { $0.isAvailable && $0.name.hasPrefix("iOS") }
            .map(\.name) ?? []
        guard !names.isEmpty else {
            return Check(passed: false, detail: String(localized: "Xcode has no iOS runtimes: add them in Xcode → Settings → Components."))
        }
        return Check(passed: true, detail: names.joined(separator: ", "))
    }

    static func simUse() -> Check {
        guard let binary = SimUse.installedBinary() else {
            return Check(passed: false, detail: String(localized: "Not installed."))
        }
        let (status, version) = ClaudeMCPInstaller.run(binary, ["--version"])
        let shownVersion = status == 0 ? " \(version)" : ""
        return Check(passed: true, detail: "\((binary.path as NSString).abbreviatingWithTildeInPath)\(shownVersion)")
    }

    /// Runs the tap and the install through Homebrew. Without Homebrew there is
    /// nothing to run: the onboarding shows the command instead.
    static func installSimUse() -> Check {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        guard let brew = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return Check(passed: false, detail: String(localized: "Homebrew not found. Install it from brew.sh and run: \(simUseInstallCommand)"))
        }
        let brewURL = URL(fileURLWithPath: brew)
        for arguments in [["tap", "lycorp-jp/tap"], ["install", "lycorp-jp/tap/sim-use"]] {
            let (status, output) = ClaudeMCPInstaller.run(brewURL, arguments)
            guard status == 0 else {
                return Check(passed: false, detail: String(localized: "`brew \(arguments.joined(separator: " "))` failed (\(status)): \(String(output.suffix(400)))"))
            }
        }
        return simUse()
    }

    // MARK: - Claude Code

    /// Passes when fingertip is registered with a server that exists. One that is
    /// not this app's (a `.build/` binary) is named; a DerivedData build that was
    /// cleaned fails, since Claude Code can no longer start it. With a Jev key saved
    /// in the app, a registration without one fails too: `run_instruction` needs it.
    static func claudeRegistration(expectsJevKey: Bool) -> Check {
        guard let claude = ClaudeMCPInstaller.resolveClaudeBinary() else {
            return Check(passed: false, detail: String(localized: "`claude` not found. Install Claude Code and check again."))
        }
        let (status, output) = ClaudeMCPInstaller.run(URL(fileURLWithPath: claude), ["mcp", "get", "fingertip"])
        guard status == 0 else {
            return Check(passed: false, detail: String(localized: "fingertip isn’t registered in Claude Code."))
        }

        // The output also lists the environment, API key included: only the command line is
        // read, and the key's line only for whether it is there.
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let command = lines
            .first { $0.hasPrefix("Command:") }
            .map { $0.dropFirst("Command:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        if expectsJevKey && !lines.contains(where: { $0.hasPrefix("TYPESAFE_API_KEY=") }) {
            return Check(passed: false, detail: String(localized: "Registered without the Jev key: register again to pass it along."))
        }
        if command == bundledMCPPath {
            return Check(passed: true, detail: String(localized: "Registered with this app’s server."))
        }
        let shown = (command as NSString).abbreviatingWithTildeInPath
        guard FileManager.default.isExecutableFile(atPath: command) else {
            return Check(passed: false, detail: String(localized: "Registered, but it points to a server that no longer exists: \(shown)"))
        }
        return Check(passed: true, detail: String(localized: "Registered with another server: \(shown)"))
    }
}
