//
//  ClaudeMCPInstaller.swift
//  Fingertip
//
//  Corre `claude mcp add` apuntando al fingertip-mcp bundleado adentro de
//  esta misma app, en vez de pedirle al usuario que lo haga a mano con un
//  path dentro de .build/. Resuelve `claude` con un shell de login porque
//  típicamente vive en el PATH de npm/nvm/Homebrew del usuario, no en el
//  de este proceso.
//

import Foundation

nonisolated enum ClaudeMCPInstaller {
    struct Result: Sendable {
        let succeeded: Bool
        let message: String
    }

    static func install(apiKey: String) -> Result {
        guard let claudePath = resolveClaudeBinary() else {
            return Result(succeeded: false, message: "No encontré `claude` en el PATH del shell de login.")
        }

        let mcpPath = Bundle.main.bundleURL
            .appending(path: "Contents/Resources/fingertip-mcp")
            .path

        // `claude mcp add` refuses a name that already exists, so updating means removing first.
        // It fails when nothing is registered yet, which is fine.
        _ = run(URL(fileURLWithPath: claudePath), ["mcp", "remove", "--scope", "user", "fingertip"])

        var arguments = ["mcp", "add", "--scope", "user", "fingertip"]
        if !apiKey.isEmpty {
            arguments += ["-e", "TYPESAFE_API_KEY=\(apiKey)"]
        }
        arguments += ["--", mcpPath]

        let (status, output) = run(URL(fileURLWithPath: claudePath), arguments)
        if status == 0 {
            return Result(succeeded: true, message: "Registrado: \(mcpPath)")
        }
        return Result(succeeded: false, message: "Falló (\(status)): \(output)")
    }

    /// The native installer puts `claude` in ~/.local/bin and adds that to PATH in .zshrc,
    /// which a login shell (`-l`) does not read; so the usual places are checked first, and
    /// an interactive shell last. Its .zshrc may print, so only the last line counts.
    static func resolveClaudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let known = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let found = known.first(where: FileManager.default.isExecutableFile(atPath:)) { return found }

        for flags in ["-lc", "-lic"] {
            let (status, output) = run(URL(fileURLWithPath: "/bin/zsh"), [flags, "command -v claude"])
            guard status == 0,
                  let path = output.split(whereSeparator: \.isNewline).last.map(String.init),
                  FileManager.default.isExecutableFile(atPath: path)
            else { continue }
            return path
        }
        return nil
    }

    static func run(_ executable: URL, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }
}
