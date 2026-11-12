---
name: fingertip
description: How to run a manual test of a macOS app or an iOS simulator app with the fingertip MCP tools (mcp__fingertip__*) — connect to the build being changed, walk a flow, verify what is on screen and close the test with evidence. Use before the first fingertip call of a session, whenever a change has to be checked in the real app (a manual acceptance criterion, a UI fix, "check how it looks", a bug from a screenshot), or when asked to drive an app.
---

# Manual testing with fingertip

fingertip reads the app through Accessibility and acts on it. Each tool's arguments are in its own description; this is how to put them together into a test that is cheap in context and leaves evidence.

## 1. Before connecting

- **Look for the project's own test catalog** (`docs/guides/manual-tests.md`, `docs/**/manual*`, the feature document's manual criteria). If there is one, follow its cases and its notes on how to read them.
- **Build first**, and connect to *that* build. In a worktree the Debug app is in that worktree's DerivedData, not the main checkout's: pass `app_path` together with `bundle_id`, from the build output (`xcodebuild … -showBuildSettings | grep -E 'BUILT_PRODUCTS_DIR|FULL_PRODUCT_NAME'`). `bundle_id` alone can attach to a copy built from another branch.
- **Never connect to an app paused under the debugger**; every read hangs.

## 2. Connect and start clean

1. `list_targets` once, if the target is not obvious.
2. `connect` with `test: "<short-name>"` when the run is a verification: it opens a test that records a trace, the screens and a video, and `end_test` closes it with a verdict. Leave `test` out to just operate an app.
3. `relaunch_app` for a clean state, then `wait_for` a text of the first screen before reading. `connect` right after launching fails with `app_not_running` or `no_window` (retry-safe): wait for the window instead of retrying in a loop.
4. **Several windows** (`ambiguous_window`, common in document and multi-window apps): `list_windows`, then `read_screen` with `window: <number>`. The choice holds until that window closes or the app relaunches, so do it once, not per action.

## 3. Read little

- **Every action already returns what changed** since the previous outline, with valid aliases; elements not listed keep their number under the new reading. Don't follow an action with `read_screen`.
- `read_screen` whole only at the start, after a context compaction, or when you need frames (only `read_screen` returns them).
- **Dense screens** (settings, long lists): `read_screen` with `skeleton: true`, then `region: "<name>"`. Later actions show only that region until a `read_screen` without `region`.
- Texts are cut at 100 characters; `full: true` when the whole text is what you are checking.
- **`screenshot` is for visuals only** — layout, color, spacing, truncation, icons — never to find what to tap. One per check; it returns at once, so a second one in a row shows the same thing.

## 4. Act

- **Tap by alias** (`@L:N`), never by coordinates from a screenshot. `select`, `set_value` and `toggle` (macOS) read the control back: prefer them over tapping a pop-up, a field or a switch by hand.
- **`screen_changed`** is the guard working, not a failure: the reply carries the current screen; pick the element's new alias from it and act again. Don't resend the same alias.
- **Wait in the server, not in your turns.** For anything that appears later (a reply, a spinner ending, a card that lasts seconds), `wait_for` with `text` (+ `gone: true` to wait for it to disappear, + `tap: true` to tap it the moment it appears) and a `timeout` that fits. On a screen with a ticking clock or countdown, wait for the end state rather than reading in between.
- **Coordinates only when the alias can't say it:** a view with no Accessibility element (a canvas, a custom drawing), or when the test is about a *real* click reaching the control (hit-testing through a toolbar or a titlebar band). Take the point from a `read_screen` frame, not from the screenshot.
- On a Mac, read the reply's `Delivery:` line: `verified` and `delivered` took; `no_effect` means the app accepted the action and nothing changed — that is a finding, not something to retry.
- **Errors are coded** (`Error <code> · retry_safe: <bool>`). Retry only when `retry_safe` is true, after reading the screen it returns. `retry_safe: false` means change the approach.

## 5. What fingertip doesn't do

- **System dialogs** (permission prompts, Touch ID, the Keychain password, open/save panels outside the app), other Mac apps, macOS notifications, restarts: ask the user to do that step, then continue.
- **Blocked apps** (terminals, editors, System Settings, password managers, other agents' apps): only the user lifts the block. Don't look for a way around it.
- **`bring_to_front`** is off until the user turns it on in the Fingertip app. If a window is on another desktop (`window_on_other_space`), ask the user.
- **Don't act while the user is using the app**; say so and stop touching it.
- What isn't on screen — files written, logs, database rows, processes — is checked from the shell, not by reading the app.

## 6. Recording and Jev

- A test opened with `connect(test:)` already records the window; `start_recording` then answers `test_in_progress`. Use `start_recording` / `stop_recording` only outside a test, when the user asks for a video.
- `run_instruction` hands a whole instruction to Jev. Use it for a long, mechanical walk where the steps don't need your judgment; drive it yourself when you are checking something.

## 7. Close with evidence

`end_test` with `passed` and `notes` that a reviewer can check without rerunning:

- which criterion or case it verifies, on which build (bundle id, branch);
- what you did and what you saw, with the on-screen texts quoted;
- what you found and fixed along the way, and what you saw and left as is;
- what you couldn't check and why (a system dialog, an external account).

Report the test the same way to the user. A failure is `passed: false` with what broke, not a test left open.
