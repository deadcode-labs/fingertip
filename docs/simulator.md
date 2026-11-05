# Driving the iOS Simulator

`SimulatorDriver` uses two layers, both needed.

## 1. `xcrun simctl` — device lifecycle

```bash
xcrun simctl list devices --json          # discover; parse runtime keys matching iOS-(\d+)-(\d+)
xcrun simctl boot <UDID>
xcrun simctl io <UDID> screenshot --type png <path>
```

Screenshots are cheap enough to poll (~150 ms) for a live mirror view. `simctl` gives pixels and lifecycle (`launch`, `terminate`, `privacy`) — it does **not** give the accessibility tree or synthetic touches.

## 2. `sim-use` — UI automation

A single Swift binary (Apache-2.0, forked from `cameroncooke/AXe`) that drives the simulator through statically linked XCFrameworks from Meta's idb (`FBSimulatorControl`), Apple's Accessibility APIs and the simulator HID pipeline. Repo: https://github.com/lycorp-jp/sim-use. Install: `brew tap lycorp-jp/tap && brew install lycorp-jp/tap/sim-use`.

**It runs no XCTest runner.** That is why it replaced `maestro-ios-driver`: nothing competes for ownership of the device, there is no port to poll and no lingering runner to kill.

Shell out to it; do not link it. Its SPM `binaryTarget`s point at XCFrameworks that are not in its repo and must be built from an idb checkout, while the released binary is standalone.

**`PATH` alone is not enough to find the binary.** A GUI app launched from Finder or Xcode inherits launchd's minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`). `SimUse.locate()` walks `PATH` and then `/opt/homebrew/bin` and `/usr/local/bin`, caching the hit. Surface a clear "sim-use not found" state rather than throwing; the app must stay usable where it isn't installed.

| Command | Purpose |
|---|---|
| `ui` / `describe-ui` | compact screen outline; `--json` for the structured envelope |
| `tap`, `long-press`, `swipe`, `touch`, `gesture`, `multi-touch` | synthetic gestures |
| `type`, `paste`, `keyboard-state` | keyboard input |
| `button`, `key`, `key-combo`, `key-sequence` | hardware + keycode input |
| `screenshot`, `record-video`, `stream-video` | pixels |
| `app-state` | which apps run, plus crash detection between calls |
| `devices`, `daemon` | discovery and daemon lifecycle |
| `ios batch` | ordered steps over one HID session and one AX snapshot |

The `ui` outline's `@N` aliases are the closed option set — Jev picks one, code runs `tap @N`:

```text
App: Settings  402x874

[Top  y<120]
  @1  StaticText  "Settings"
[Content  y=120..754]
  @5  SearchField  "Search"        #settingsSearch  (20,202 362x28)
  @9  Button       "General"
[Bottom  y>754]
  @43 TabBar
```

Selectors, in descending order of preference: `@N` (alias cached from the last `ui`), `#<id>` (the app's `accessibilityIdentifier`), `--label "General"` (with `--wait-timeout` for scripted waits), `-x/-y` (last resort).

## Measured behaviour

sim-use 0.14.0, iPhone 18 Pro / iOS 27:

- **There is no tree.** `entries` comes back flat — every entry has `depth: 1` — and `data.raw` is flat too. What orders a screen is `region` (`Top` / `Content` / `Bottom`), not nesting. Do not try to reconstruct a tree.
- **The `@N` aliases are a cache, and re-reading is correctness, not hygiene.** `ui` writes them to `~/.sim-use/<udid>/last-outline.json` and `tap @N` reads them back without touching the device. Act without a fresh `ui` and the tap lands on the *previous* screen's element. `ScreenInspector.perform` re-reads after every action for this reason.
- **Latency**: `ui` is ~0.56 s warm, ~1.56 s cold. The cold cost is a per-UDID background daemon; it is automatic, self-exits after 600 s idle and logs to `/tmp/sim-use-<uid>/<UDID>.log`. Do not manage it.
- **Size**: outline 2.2 KB vs 23 KB for the raw JSON tree. Always pass `--json --no-raw` (8.5 KB) in the agent loop.
- **No app lifecycle.** There is no `launchApp` / `terminateApp` / `setPermissions`; `app-state` only reports. Use `xcrun simctl launch|terminate|privacy`.
- The `--json` envelope is `{ok, data}` with `data` = `appLabel`, `appPackage`, `entries`, `lists`, `orientation`, `outline`, `platform`, `screen`. Each entry carries `aliases`, `depth`, `frame {x,y,width,height}`, `label`, `region`, `role`, `states`, `uniqueId`.
- **`role` is already a name** (`Button`, `CheckBox`, `StaticText`), not a numeric `XCUIElement.ElementType`, and frames use lowercase keys. No mapping layer is needed — do not reintroduce one.
- `ui` self-calibrates orientation per call; AX selectors work rotated. Explicit `-x/-y` is device-native portrait space.
- **Coordinate spaces differ between verbs.** `describe-ui` prints frames in `ui` space; `swipe` defaults to `--coordinate-space native`. They diverge rotated, so pass `--coordinate-space ui` on swipes built from outline frames. `tap` has no such flag — coordinate taps are portrait-only.
- **No erase verb.** Deleting text is `ios key-sequence --keycodes 42,42,…` (HID 42 = backspace), one keycode per character.
- **`type` is US-keyboard only and `paste` does not work on this machine.** `type` sends HID keycodes, so `é`, `ñ`, `£` fail loudly (`No keycode found for character: 'é'`). `paste` copies via `xcrun simctl pbcopy`, which needs Simulator.app running to sync the pasteboard, and there is no Simulator.app here — `paste` returns `{"ok":true}` having written nothing. `--via-menu` fails too. Do not "fix" typing by switching to `paste`; a silent no-op is worse than the error. `SimUse.perform` validates the string first and names the offending characters.
- Errors come back in the envelope with an actionable `hint` field — surface it, don't swallow it.
- **`No translation object returned for simulator` on every `ui` means the simulator's accessibility bridge is stale**, not a dialog on screen (0.14.0's hint blamed a fullscreen dialog; 0.16.0 names the bridge). `screenshot` and `ui --point` still work, and neither a daemon restart nor a simulator reboot fixes it. Restart the bridge: `xcrun simctl spawn <UDID> launchctl stop com.apple.CoreSimulator.bridge` (launchd restarts it at once). Seen 2026-11-05 with Device Hub open; it has nothing to do with the Device Hub window.
- Validate every UDID (8-4-4-4-12 hex) before passing it to a process. A Swift regex *literal* for this pattern trips the parser here — `SimUse.isValidUDID` splits on `-` and checks group lengths instead.
