# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- First-launch onboarding in the Fingertip app: steps that check Xcode's iOS runtimes and sim-use (with a button that installs sim-use through Homebrew), fingertip's registration in Claude Code (flagging one that points at a server that no longer exists) and the Mac permissions. It opens by itself until finished once; the menu reopens it with **Configuración inicial…**.

## [0.2.2] - 2026-11-02

### Security
- `run_instruction`'s run log no longer stores the instruction verbatim: every text Jev could type from it (emails, quoted text, tokens with digits) is written as `[texto]`, since it may be a password.
- More Mac apps are blocked for the MCP: Hyper, Tabby, VS Code Insiders, VSCodium, Windsurf, Zed, Nova, Android Studio and every JetBrains IDE (by `com.jetbrains.` prefix), Raycast, Alfred, Keyboard Maestro, and System Settings, where privacy permissions are granted.

## [0.2.1] - 2026-11-02

### Changed
- New app icon for Fingertip: a finger pressing a button, on the standard macOS icon grid (824-point rounded square with transparent margin).

### Removed
- `scripts/generate-app-icon.swift`, which drew the old icon.

## [0.2.0] - 2026-11-02

### Removed
- The Jev app (`App/flowforge-jev`): `run_instruction` runs the same agent from Claude Code and the Fingertip app shows its steps. Run logs keep going to `~/Library/Application Support/flowforge-jev/runs/`. With it go the API only it used: `Simctl.shutdown`, `MacApp.isXcodeBuild`, `JevAgent.tap(_:)`, and `requireWindowChoice` (a Mac app with several windows now always needs a choice).

### Added
- Pop-up and menu buttons on macOS: tapping one opens its menu for real (`AXPress`, then `AXShowMenu`, then a click, each confirmed by the menu appearing as the control's child) and the next reading lists its items in `Menú` as `Flavor › Mint`; tapping it again closes it, and opening a second menu while one is open is refused (`menu_already_open`). Calculator's "Mode", which `AXPress` and `AXShowMenu` both answer without opening, now opens with a click.
- MCP `select` (`alias`, `option`): opens a pop-up or menu button, picks the item by name and reads the control back; with no such item it cancels the menu and lists the options (`option_not_found`).
- MCP `set_value` (`alias`, `value`) and `toggle` (`alias`), macOS only: write a field's text through the field editor (so a SwiftUI binding sees it), a date picker's date or a slider's number, or flip a checkbox, radio or switch, and read the result back. A read-only element is `not_settable`; a change that does not take is `no_effect`; on the simulator both are `unsupported`.
- Delivery report: each Mac action returns the strategies it tried and what each did (`not_delivered`, `no_effect`, `delivered`, `verified`), shown as the `Entrega:` line of the MCP reply (`ScreenDriver.perform` returns `[DeliveryStep]`, `ScreenInspector.lastDelivery` keeps them).
- Windows: MCP `list_windows`, and `read_screen` with `window` to choose one; the choice holds until the window closes (`window_gone`) or the app relaunches. Through the MCP, a Mac app with several windows and none chosen fails with `ambiguous_window`, listing them; `connect` still connects. Windows are identified by window number plus process start time.
- Screen recording: the MCP's `start_recording` and `stop_recording` record a `.mov` of the simulator (`simctl io recordVideo`, closed with SIGINT) or of a Mac app's window (ScreenCaptureKit `SCRecordingOutput`) and return its path. One recording per driver at a time (`already_recording`, `not_recording`), closed cleanly on `disconnect`, on SIGTERM/SIGINT/SIGHUP, or when the server's stdin ends; a `connect` that switches device names the recording it closed. The folder is a new setting in the Fingertip app (Settings → Capturas → Grabaciones).
- Destructive-step gate in `JevAgent`: a tap chosen with confidence between 0.6 and 0.9 is rated by a second Jev request (a `destructive` Noul). At 0.5 risk or more the step needs 0.9 confidence, so it stops and hands the choice to the user; a rating that fails counts as destructive. `run_instruction` says when a step was held for risk rather than for low confidence, and the run log records `risk`.
- Read dense screens by region: `read_screen` takes `skeleton: true` (each region with its element count) and `region` (only that region, kept as the focus for later actions until a whole read). On macOS each scroll area is now its own region, named from AX (Finder reads as `sidebar` and `icon view`). `JevAgent` does the same above 60 actionable elements: Jev chooses a region to look inside first, and can go back to the whole window.
- Virtual pointer: while the Fingertip menu-bar app is running, every tap or scroll on a Mac app shows a ghost pointer that glides to the element, outlines it and labels it, then fades out. The real cursor never moves, and the pointer follows a window moved since the last reading. Events travel as JSON lines over the existing `ActivityBeacon` socket (`OverlayEvent`); writes are non-blocking and `SO_NOSIGPIPE`, so a missing or dead app never affects a tool call, a partial write never splits a line, and the next event reconnects to a restarted app. The app handles events from all connections in the order they arrive, keeps accepting after transient `accept` failures, and closes a connection that sends a line over 64 KB.
- Status toast: the Fingertip app shows what the agent is doing — the tool running, each Jev step with its confidence, an error with its code, a run held for the user — and `Pensando…` between calls. Typed text and `run_instruction`'s instruction are never shown, only their length or a generic label, since they may hold a password; a run that runs out of steps says it stopped short. An optional Claude Code `Stop` hook (see `docs/mcp.md`) makes it say `Listo` when the turn ends; it sends its `$PPID`, matched against the Claude Code process that spawned the MCP, so with two sessions open one ending doesn't cut off the other. A connection now counts as a session only after it sends `OverlayEvent.session`, so the hook doesn't light the edge indicator.
- Coded errors: every failure carries a stable `code` and `retry_safe`, through the new `FingertipError` protocol. The MCP prints both on the first line of an error and returns them in `structuredContent`; a retry-safe action failure comes with the current screen. `ScreenInspector.failure` and `JevAgent.failure` hold the error; `errorMessage` is now derived from it.

### Changed
- `tap` on macOS reads back what it can and moves on when nothing happened: a press inside a row counts when the row got selected or the window changed, otherwise the row is selected instead; an element's or ancestor's `AXOpen` is tried, which makes Finder's sidebar navigate instead of only highlighting the row; a child that is the same control (same name) is activated. An "unsupported" answer to an action the element advertises is checked against the window, since Finder answers `-25205` to an `AXOpen` that navigates.
- The real-click fallback on macOS waits until the app's window is the one under the point (it may be on another Space, behind a full-screen terminal) and AX lists it, instead of a fixed 300 ms; if it never is, it sends no click and fails with `not_clickable`, where it used to click whatever covered the app.
- `retry_safe` of a failed AX action now depends on its AX error: safe when it says the call never ran (unsupported, invalid element), not for a timeout or a generic failure.
- Screenshots of a Mac app pick the window by its number instead of its frame, so two windows with the same frame no longer get mixed up.
- The Fingertip settings window has a sidebar with three sections: General (Claude Code registration), Capturas (folders, with Show in Finder and Use default) and Jev (API key). Registering runs off the main thread, and a settings file that fails to save is reported instead of ignored.
- Aliases carry the reading they came from: the outline shows `@L:N` and `tap` takes `alias: "L:N"`; a bare `N` is rejected. `tap` re-reads first and refuses with `screen_changed` if the element or anything before it changed since reading L, instead of tapping whatever now sits at that position. `JevAgent` taps through the same check; a change while Jev was deciding ends the step as `screenChanged` and the run continues.

### Fixed
- A Mac app with windows on another desktop (Space) read as having only its focused window: `list_windows` said it had none, `read_screen` read the focused one with no `ambiguous_window`, and choosing another gave `unknown_window`. Those windows are now found through the window server, count towards `ambiguous_window`, are listed as `[en otro escritorio]`, and choosing one AX cannot reach gives `window_on_other_space`; an inactive tab does not count. A chosen window that moves to another desktop gives that error instead of `window_gone`, and the choice holds. It needs Screen Recording, as screenshots do.
- The Fingertip edge indicator stayed on for the whole Claude Code session: the MCP opened its session at the first `connect` and never closed it. It now opens the session for each tool call and closes it 30 s after the last one, and the app hides the edge as soon as the Stop hook reports the end of that session's turn. The status toast keeps telling a Jev run's outcome apart (`goal_reached`, `needs_user`, `stopped`) now that `run_instruction` no longer returns `structuredContent` on success.
- A password field's value is never shown in a reading, whatever the app exposes.
- macOS actions no longer report success they did not have. `select` on a toolbar button with no menu ran it through the click fallback and answered `menu_did_not_open` with `retry_safe: true`; the click is now reported as having run the button and the error is not retry-safe, and a menu that opens late is cancelled. A press in a row that was already selected, or `AXSelected` on one, no longer verifies itself. `select` treats an item press that leaves the menu open as `no_effect`, and does not take text the control showed before the press as proof. `toggle` waits for a late press before clicking, so it no longer flips a control twice. `set_value` reads back over 600 ms and accepts a slider's rounding.
- Mac windows: the click fallback raises the chosen window and refuses to click into another window of the same app; coordinate taps and the effect checks no longer swallow `window_gone` / `ambiguous_window` or drop the chosen window silently. A control that keeps a closed `AXMenu` child no longer reads as an open menu.
- A `sim-use` or `simctl` call that never returned hung the MCP: it serves one message at a time, so every tool after it waited forever. Both now run with a deadline (30 s for `sim-use`, 60 s for `simctl`, 180 s for `simctl boot`) and fail with `process_timed_out`, retry-safe for reads (`ui`, listing devices, screenshots) and not for actions. The command and everything it spawned are killed, and their pipes are drained off the cooperative thread pool.
- A cancelled `sim-use` or `simctl` call returned at once and left the command running; the command now gets SIGTERM (and the deadline's SIGKILL if it ignores it) and the call throws `CancellationError`.
- macOS actions judged "the window changed" against two baselines: a press inside a row and an action answered "unsupported" compared with the last reading, other checks with the window just before acting. All of them now take the window just before acting.
- Two `start_recording` calls on a Mac app racing each other could open two streams and leave one running; the first claims the recording before it suspends.
- The Fingertip edge indicator's fade-out could take the window off screen after it had been shown again; it is now hidden from the main actor, and only if it is still meant to be hidden. The build has no compiler warnings.
- A Jev run's JSONL log stored the text typed into a field, which may be a password taken from the instruction. It now stores only `text_length`.
- `run_instruction` returned `structuredContent` (`{"result": …}`) on success too, and Claude Code shows that instead of the text, so the steps, the log path and the screen never reached the caller. Successful replies are text only; structured content stays on errors.
- The MCP `screenshot` tool ignored the folder chosen in the Fingertip app and always wrote to `$TMPDIR/fingertip-mcp/`; the app only changed where Jev runs go. `screenshot` now has its own setting (`screenshotsDirectory`), read on every call, keeps the temporary folder as default, uses a timestamped file name that never overwrites an earlier capture, and says so when it can't write the PNG.

## [0.1.0] - 2026-10-30

First release. fingertip lets an agent see and drive an iOS simulator or a macOS app; it grew out of the `flowforge-jev` proof of concept, whose history it keeps.

### Added
- `fingertip-mcp`, an MCP server that lets Claude Code drive a simulator or a Mac app: `list_targets`, `connect`, `read_screen`, `wait_for`, `tap`, `type_text`, `erase_text`, `submit` (Return), `scroll`, `swipe`, `press_button`, `screenshot`, `relaunch_app`, `terminate_app` and `run_instruction`. Every action returns the new screen. `wait_for` polls inside the server and can tap the moment an element appears, so short-lived UI (an approval card) is not missed between Claude turns. Long texts are cut in the outline; `full: true` returns them whole.
- Sensitive Mac apps (terminals, editors with integrated terminals, Claude, automation tools, password managers) are blocked for the MCP unless the user registers it with `FINGERTIP_UNRESTRICTED=1`.
- `MacDriver`: macOS apps as a second kind of target, read and driven through the Accessibility API with the app in the background and the cursor untouched, and captured with ScreenCaptureKit. It taps, types any Unicode, submits with a Return posted to the pid, scrolls through the scroll bar, lists menu-bar items without opening menus, and reads SwiftUI `Form` controls named by their label. It refuses to signal an app under the debugger and tells apart two running copies with the same bundle id.
- `SimulatorDriver` over [`sim-use`](https://github.com/lycorp-jp/sim-use) (Apache-2.0) and `xcrun simctl`: list, boot and shut down simulators, read the screen as a flat list grouped by region, tap by `@N` alias with the element centre as fallback, type, erase, swipe, press hardware buttons, launch and terminate the app under test. No XCTest runner, so nothing competes for the device. Text the US keyboard cannot type is rejected up front, naming the characters.
- The Jev agent (`JevAgent`): each step asks TypeSafe's System One one request with `next_element` (a Choice over the visible actionable elements plus `ninguno`, `scroll_abajo` and `scroll_arriba`), `goal_reached` (a Noul) and, when the instruction contains literal text, `text_to_type` (a Choice over strings extracted from it). It acts above 0.6 confidence, stops when the goal passes 0.5, hands the decision to the user otherwise and stops at 10 steps. Jev sees the history of steps already taken.
- Every run can start from the app's initial screen: with a bundle id set, the agent kills and relaunches the app and waits for its accessibility tree to settle before the first step.
- A run stops when the app under test dies instead of deciding on the home screen; the step is logged as `app_crashed`.
- Run log: one JSONL line per step (candidates, choice, confidence, `goal_reached`, typed text, latency, tokens), plus a screenshot after each action and whenever the screen changes on its own, deduplicated by hash across the run.
- The Jev app (SwiftUI): simulator and Mac app list, live mirror, screen inspector with manual actions, and an instruction bar that shows each step as it happens. The TypeSafe key is read from `TYPESAFE_API_KEY`, set in a user scheme that git ignores.
- MIT license.

### Changed
- The project is called fingertip and lives in `deadcode-labs/fingertip`. The package is at the repo root — `FingertipCore` (formerly `FlowforgeCore`) and `fingertip-mcp` (formerly `flowforge-mcp`) — and the Jev app is in `App/`. The app's target, scheme and bundle id stay `flowforge-jev` so it keeps its Accessibility and Screen Recording grants.
- Simulator automation moved from `maestro-ios-driver` to `sim-use` during the proof of concept: no `.xctestrun` to unpack, no port to wait on, no stale runners to kill.

### Removed
- `MaestroDriver`, the XCUITest hierarchy parsing and Maestro as a dependency.

[Unreleased]: https://github.com/deadcode-labs/fingertip/compare/v0.2.2...HEAD
[0.2.2]: https://github.com/deadcode-labs/fingertip/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/deadcode-labs/fingertip/releases/tag/v0.2.1
