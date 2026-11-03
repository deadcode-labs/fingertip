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
            return Check(passed: false, detail: "`xcrun simctl` no responde: instalá Xcode y abrilo una vez.")
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
            return Check(passed: false, detail: "Xcode no tiene runtimes de iOS: agregalos en Xcode → Settings → Components.")
        }
        return Check(passed: true, detail: names.joined(separator: ", "))
    }

    static func simUse() -> Check {
        guard let binary = SimUse.installedBinary() else {
            return Check(passed: false, detail: "No está instalado.")
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
            return Check(passed: false, detail: "No encontré Homebrew. Instalalo desde brew.sh y corré: \(simUseInstallCommand)")
        }
        let brewURL = URL(fileURLWithPath: brew)
        for arguments in [["tap", "lycorp-jp/tap"], ["install", "lycorp-jp/tap/sim-use"]] {
            let (status, output) = ClaudeMCPInstaller.run(brewURL, arguments)
            guard status == 0 else {
                return Check(passed: false, detail: "`brew \(arguments.joined(separator: " "))` falló (\(status)): \(output.suffix(400))")
            }
        }
        return simUse()
    }

    // MARK: - Claude Code

    /// Passes when fingertip is registered with a server that exists. One that is
    /// not this app's (a `.build/` binary) is named; a DerivedData build that was
    /// cleaned fails, since Claude Code can no longer start it.
    static func claudeRegistration() -> Check {
        guard let claude = ClaudeMCPInstaller.resolveClaudeBinary() else {
            return Check(passed: false, detail: "No encontré `claude`. Instalá Claude Code y volvé a verificar.")
        }
        let (status, output) = ClaudeMCPInstaller.run(URL(fileURLWithPath: claude), ["mcp", "get", "fingertip"])
        guard status == 0 else {
            return Check(passed: false, detail: "fingertip no está registrado en Claude Code.")
        }

        // Only the command line is read: the output also lists the environment, API key included.
        let command = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("Command:") }
            .map { $0.dropFirst("Command:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        if command == bundledMCPPath {
            return Check(passed: true, detail: "Registrado con el servidor de esta app.")
        }
        let shown = (command as NSString).abbreviatingWithTildeInPath
        guard FileManager.default.isExecutableFile(atPath: command) else {
            return Check(passed: false, detail: "Registrado, pero apunta a un servidor que ya no existe: \(shown)")
        }
        return Check(passed: true, detail: "Registrado con otro servidor: \(shown)")
    }
}
