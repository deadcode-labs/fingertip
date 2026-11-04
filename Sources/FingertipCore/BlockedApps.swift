//
//  BlockedApps.swift
//  FingertipCore
//
//  The Mac apps the MCP refuses to drive: where typing and pressing Return
//  amounts to running code or touching secrets. Everything the server reads
//  off a screen reaches Claude as text, so an instruction hidden in a page or
//  an email could steer it into a terminal. The app's Security pane shows this
//  list, lets the user unblock entries one by one and add their own.
//

import Foundation

public nonisolated enum BlockedApps {
    public struct Group: Sendable, Identifiable {
        public let name: String
        public let bundleIDs: [String]
        public var id: String { name }
    }

    /// Fingertip itself: its Settings holds the switches that lift the block, so it can
    /// never be unblocked on its own; only god mode (`FINGERTIP_UNRESTRICTED=1`) lifts it.
    public static let fingertip = "com.maxward.fingertip"

    /// An ID ending in "." matches every bundle id with that prefix.
    public static let jetBrainsPrefix = "com.jetbrains."

    /// Lowercased: Launch Services resolves bundle ids case-insensitively.
    public static let builtIn: [Group] = [
        Group(name: "Terminales", bundleIDs: [
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty",
            "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
            "co.zeit.hyper", "org.tabby",
        ]),
        // Cursor is com.todesktop.…
        Group(name: "Editores con terminal", bundleIDs: [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
            "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
            "dev.zed.Zed", "dev.zed.Zed-Preview", "com.panic.Nova", "com.google.android.studio",
            jetBrainsPrefix,
        ]),
        // The current ChatGPT app is com.openai.codex too; com.openai.chat is the older one.
        Group(name: "Otros agentes", bundleIDs: [
            "com.anthropic.claudefordesktop", "com.openai.codex", "com.openai.chat",
        ]),
        Group(name: "Scripts y automatización", bundleIDs: [
            "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts",
            "com.raycast.macos", "com.runningwithcrayons.Alfred", "com.stairways.keyboardmaestro.editor",
        ]),
        Group(name: "Sistema", bundleIDs: ["com.apple.systempreferences"]),
        Group(name: "Contraseñas", bundleIDs: [
            "com.apple.keychainaccess", "com.apple.Passwords", "com.1password.1password",
            "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.lastpass.LastPass",
        ]),
    ].map { Group(name: $0.name, bundleIDs: $0.bundleIDs.map { $0.lowercased() }) }

    /// Whether the MCP must refuse `bundleID`. `unrestricted` is god mode, decided at registration.
    public static func isBlocked(_ bundleID: String, unrestricted: Bool, settings: FingertipSettings) -> Bool {
        guard !unrestricted else { return false }
        let id = bundleID.lowercased()
        if id == fingertip { return true }
        let listed = (builtIn.flatMap(\.bundleIDs) + settings.extraBlockedApps).first { matches(id, $0) }
        guard let listed else { return false }
        return !settings.unblockedApps.contains(listed)
    }

    private static func matches(_ id: String, _ entry: String) -> Bool {
        entry.hasSuffix(".") ? id.hasPrefix(entry) : id == entry
    }
}
