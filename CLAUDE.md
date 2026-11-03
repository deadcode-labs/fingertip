# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

fingertip lets an agent see and drive an iOS simulator or a macOS app: read the screen through Accessibility, tap, type, scroll. Two parts:

- **The repo root is a Swift package**, no UI: library `FingertipCore` (drivers, Jev, the agent loop) in `Sources/FingertipCore/`, and executable `fingertip-mcp` (MCP server for Claude Code) in `Sources/fingertip-mcp/`.
- **`App/Fingertip/`** — the Fingertip menu-bar app, depending on `FingertipCore` through a local package reference: edge indicator, status toast and pointer overlay while the MCP acts, settings, and registering the MCP in Claude Code. Jev runs go to `~/Library/Application Support/flowforge-jev/runs/`, named after the removed Jev app; keep the path so earlier runs stay together.

`JevAgent` and `ScreenInspector` only see `protocol ScreenDriver`; `SimulatorDriver` (over `sim-use` + `simctl`) and `MacDriver` (over the Accessibility API + ScreenCaptureKit) are the two implementations.

Reference, read when touching that area:

- `docs/jev.md` — Jev's primitives, the per-step questions and thresholds, the API.
- `docs/simulator.md` — `simctl` and `sim-use`, with measured behaviour.
- `docs/macos.md` — `MacDriver` and what the Accessibility API does and doesn't do.
- `docs/mcp.md` — the MCP tools, their design and registration.

## Rules

- **There is no test target, by decision — do not add one and do not propose adding one.** Max decided this on 2026-09-20. Do not write `XCTest`/`Swift Testing` files, do not create a test target, and do not treat the absence as a gap in a roadmap or a review. Prove a change by running it against a booted simulator or a running Mac app and showing the output.
- **Jev chooses, it never generates.** It answers typed questions (Choice / Score / Noul) about a closed option set that Swift code enumerates. If a step needs free-form generation, restructure it as a Choice. Never act on a low-confidence Choice; surface the ambiguity to the user instead.
- **Re-read after every action.** sim-use's `@N` aliases are a cache of the last `ui`; acting on a stale one taps the previous screen. `ScreenInspector.perform` does this — go through it.
- **stdout is the MCP protocol.** Nothing in `FingertipCore` may `print`; diagnostics go to stderr.
- Anything the app or the MCP touches from the package must be `public`; the rest stays internal.
- `ENABLE_APP_SANDBOX` is **`NO`** in the app, deliberately: a sandboxed app cannot spawn `xcrun simctl` or `sim-use`. Do not turn it back on.
- Swift 6 language mode, `MainActor` default isolation and approachable concurrency, in both the app and the package, so code moves between them unchanged. Process wrappers and pollers cross isolation boundaries — make them actors from the start.
- Do not work around `sim-use type`'s US-keyboard limit with `paste`: on this machine `paste` returns ok and writes nothing.
- Never signal a Mac app under the debugger (`MacDriver` refuses with `underDebugger`); Xcode leaves it paused and every AX read hangs.
- The MCP blocks sensitive Mac apps (terminals, editors with terminals, System Settings, password managers…). Only the user lifts it, with `FINGERTIP_UNRESTRICTED=1` at registration — never add a tool argument for it.
- iOS Simulator and macOS apps on this Mac only — no Android, no physical devices.

## Language

Code comments and `CHANGELOG.md` entries are always in **English**, including when the conversation is in Spanish. Existing Spanish comments and entries predate this rule; write English in anything new or touched. Strings the code emits (`ninguno`, `[marcado]`, region names…) are data, not comments — leave them alone unless asked.

## Commands

From the repo root:

```bash
swift build                # the package, debug
swift build -c release     # the binary Claude Code runs as the fingertip MCP
xcodebuild -project App/Fingertip.xcodeproj -scheme Fingertip -destination 'platform=macOS' build
```

Building is the whole automated check. To verify behaviour, drive a device: through the `fingertip` MCP tools if this session has them, by piping JSON-RPC lines into `.build/debug/fingertip-mcp`, or with sim-use directly (`sim-use ui --device <UDID>`). After changing the package, rebuild in release and reconnect the MCP (`/mcp`).

Environment: Xcode 27.0 · Swift 6.4 · macOS 27.0 · sim-use 0.14.0 · iOS 27.0 and 26.5 simulator runtimes.
