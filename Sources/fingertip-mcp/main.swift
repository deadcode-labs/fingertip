//
//  main.swift
//  fingertip-mcp
//
//  MCP server over stdio so Claude Code can run manual tests on an iOS
//  simulator or a macOS app. Register it with:
//
//      claude mcp add fingertip -- <path>/fingertip-mcp
//
//  Terminals, editors with a terminal, Claude and password managers are
//  blocked; `-e FINGERTIP_UNRESTRICTED=1` at registration lifts that.
//
//  macOS permissions (Accessibility, Screen Recording) belong to the
//  responsible process, which launched from Claude Code is the terminal, not
//  this binary. They are only needed for macOS apps.
//

import AppKit
import FingertipCore

// `fingertip-mcp capture|record`: the ScreenCaptureKit child the MCP runs for each
// screenshot and recording (see `WindowCapture`). Its stdout is a pipe to the MCP.
if let status = await WindowCapture.runChild(Array(CommandLine.arguments.dropFirst()), output: .standardOutput) {
    exit(status)
}

// ScreenCaptureKit no longer runs here (see `WindowCapture`); the MCP still sets
// up AppKit, which `MacDriver` reaches through `NSWorkspace` and `NSRunningApplication`.
_ = NSApplication.shared

let session = Session()
let server = MCPServer(
    name: "fingertip",
    version: "0.7.0",
    instructions: """
    Manually test an iOS simulator or a macOS app: read the screen, tap, type, scroll and verify. \
    Typical flow: `list_targets` → `connect` → `relaunch_app` for a clean start → `read_screen` → actions \
    (each returns the new screen) → `screenshot` to check visuals. `@L:N` aliases carry the reading \
    number: `tap` refuses one if the screen changed before that element. On dense screens, \
    `read_screen` with `skeleton` and then `region`. Every error carries a code and `retry_safe`. \
    `run_instruction` delegates a whole instruction to Jev.
    """,
    tools: session.tools,
    status: session.status
)

// A signal ends the process without returning from `serve()`, which would leave a `simctl
// recordVideo` child recording forever. Close the recording first, then exit.
let signalQueue = DispatchQueue(label: "fingertip-mcp.signals")
let signalSources = [SIGTERM, SIGINT, SIGHUP].map { signalNumber -> DispatchSourceSignal in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
    source.setEventHandler { @Sendable in
        Task { @MainActor in
            await session.shutdown()
            exit(0)
        }
    }
    source.resume()
    return source
}

await server.serve()
await session.shutdown()
withExtendedLifetime(signalSources) {}
