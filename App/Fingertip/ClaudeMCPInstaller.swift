//
//  ClaudeMCPInstaller.swift
//  Fingertip
//
//  Runs `claude mcp add` pointing at the fingertip-mcp bundled inside this
//  app, instead of asking the user to do it by hand with a path inside
//  .build/. Resolves `claude` with a login shell because it usually lives
//  in the user's npm/nvm/Homebrew PATH, not in this process's.
//

import Foundation

nonisolated enum ClaudeMCPInstaller {
    struct Result: Sendable {
        let succeeded: Bool
        let message: String
    }

    /// UserDefaults key for the "god mode" switch in Settings. The MCP never reads it:
    /// it only decides whether `install` registers the server with `FINGERTIP_UNRESTRICTED=1`.
    static let unrestrictedKey = "unrestrictedMCP"

    static func install(apiKey: String, unrestricted: Bool) -> Result {
        guard let claudePath = resolveClaudeBinary() else {
            return Result(succeeded: false, message: String(localized: "`claude` not found in the login shell’s PATH."))
        }

        let mcpPath = Bundle.main.bundleURL
            .appending(path: "Contents/Resources/fingertip-mcp")
            .path

        // Without a key in this app's Keychain, keep the one already registered: re-registering
        // (the "god mode" switch does it) must not silently drop `run_instruction`'s key.
        var apiKey = apiKey
        if apiKey.isEmpty {
            let (_, current) = run(URL(fileURLWithPath: claudePath), ["mcp", "get", "fingertip"])
            apiKey = current
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("TYPESAFE_API_KEY=") }
                .map { String($0.dropFirst("TYPESAFE_API_KEY=".count)) } ?? ""
        }

        // `claude mcp add` refuses a name that already exists, so updating means removing first.
        // It fails when nothing is registered yet, which is fine.
        _ = run(URL(fileURLWithPath: claudePath), ["mcp", "remove", "--scope", "user", "fingertip"])

        var arguments = ["mcp", "add", "--scope", "user", "fingertip"]
        if !apiKey.isEmpty {
            arguments += ["-e", "TYPESAFE_API_KEY=\(apiKey)"]
        }
        if unrestricted {
            arguments += ["-e", "FINGERTIP_UNRESTRICTED=1"]
        }
        arguments += ["--", mcpPath]

        let (status, output) = run(URL(fileURLWithPath: claudePath), arguments)
        if status == 0 {
            return Result(succeeded: true, message: String(localized: "Registered: \(mcpPath)"))
        }
        return Result(succeeded: false, message: String(localized: "Failed (\(status)): \(output)"))
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
