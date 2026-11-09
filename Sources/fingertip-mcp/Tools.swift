//
//  Tools.swift
//  fingertip-mcp
//
//  The tools Claude Code sees. They are the same pieces the app uses —
//  `ScreenInspector` over a `ScreenDriver`, and `JevAgent` to delegate a whole
//  run—, so a simulator and a Mac app are driven the same way.
//
//  Every action re-reads the screen and returns it: `@N` aliases come from the
//  last reading, and tapping without re-reading aims at the previous screen.
//

import AppKit
import FingertipCore
import ImageIO
import UniformTypeIdentifiers

/// Failures of the tools themselves, before or around the device.
nonisolated enum ToolError: FingertipError {
    case invalidArguments(String)
    case blockedApp(String)
    case notConnected(String)
    case appNotFound(String)
    case appVanished(String)
    case timedOut(String)
    case bringToFrontDisabled
    case noTest
    case testInProgress(String)

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .blockedApp: "blocked_app"
        case .notConnected: "not_connected"
        case .appNotFound: "app_not_found"
        case .appVanished: "app_vanished"
        case .timedOut: "timed_out"
        case .bringToFrontDisabled: "bring_to_front_disabled"
        case .noTest: "no_test"
        case .testInProgress: "test_in_progress"
        }
    }

    /// Waiting again is harmless; the rest need a different call or the user.
    var retrySafe: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .blockedApp(let message), .notConnected(let message),
             .appNotFound(let message), .appVanished(let message), .timedOut(let message),
             .testInProgress(let message):
            message
        case .bringToFrontDisabled:
            "Bringing windows to the front is turned off: the user turns it on in Fingertip → Settings → General → Windows. No reconnect needed."
        case .noTest:
            "No test is open: open one with `connect` and `test`."
        }
    }
}

extension ToolResult {
    static func invalid(_ message: String) -> ToolResult {
        .error(ToolError.invalidArguments(message))
    }
}

final class Session {
    private let inspector = ScreenInspector()

    /// Closes what outlives a call: a recording left open would leave an unplayable `.mov`.
    func shutdown() async {
        // Before disconnecting: the test's video and verdict must be closed while the driver is there.
        _ = await closeTest(passed: nil, notes: nil)
        await inspector.disconnect()
    }
    private lazy var agent = JevAgent(inspector: inspector)
    private let simctl = Simctl()
    private var target: Target?
    /// The test opened by `connect(test:)`; while it is open every call goes to its trace.
    private var test: TestSession?
    /// Region `read_screen` was pointed at; every outline shows only it until a whole read.
    private var focusRegion: String?
    /// What the last outline showed of each element, so the next action can reply with only
    /// what changed. `nil` makes the next outline whole.
    private var shown: Shown?
    /// Past this many elements the outline suggests reading by region.
    private static let denseThreshold = 150

    /// Long side of the image returned inline. The full capture stays on disk:
    /// a retina window as PNG weighs megabytes and adds nothing to a decision.
    private static let inlineImageSide = 1280

    var tools: [Tool] {
        [
            Tool(
                name: "list_targets",
                description: "Lists the iOS simulators (UDID, runtime, whether booted) and the running macOS apps. The starting point for choosing what to test with `connect`.",
                handler: { _ in await self.listTargets() }
            ),
            Tool(
                name: "connect",
                description: "Chooses the device the other tools act on and returns its screen. Pass `udid` for a simulator (booted if needed) or `bundle_id` for a macOS app (launched if not running; `app_path` disambiguates when there are two copies, e.g. the Xcode build and the one in /Applications). With exactly one booted simulator, the other tools connect on their own.",
                properties: [
                    "udid": ["type": "string", "description": "Simulator UDID."],
                    "bundle_id": ["type": "string", "description": "Bundle id of the macOS app."],
                    "app_path": ["type": "string", "description": "Path to the .app, when more than one copy has the same bundle id."],
                    "test": ["type": "string", "description": "Only when testing: the test's name. Opens a folder that keeps every call, the screen after each one, a video of the whole test and the Jev runs, until `end_test`. Without `test`, using the app leaves nothing on disk."]
                ],
                handler: { await self.connect($0) }
            ),
            Tool(
                name: "read_screen",
                description: "Reads the current screen as a list of elements grouped by region: `@L:N Type \"label\" #identifier (x,y widthxheight)`, where L is the reading number and N the element. `tap` takes the full alias; if the screen changed before that element, it refuses instead of tapping something else. Long texts come cut to one line with «…»; `full: true` returns them whole. On a dense screen, `skeleton: true` returns only the regions with how many elements each has, and `region` shows a single one: later actions also show only that one, until a `read_screen` without `region`. If a macOS app has several windows, it fails with `ambiguous_window` until you choose one with `window` (the number from `list_windows`); the choice holds for later tools.",
                properties: [
                    "full": ["type": "boolean", "description": "Full texts, uncut."],
                    "skeleton": ["type": "boolean", "description": "Only the regions and how many elements each has."],
                    "region": ["type": "string", "description": "Name of the region to show, as it appears in brackets."],
                    "window": ["type": "integer", "description": "macOS: window number from `list_windows`. Reads that window and keeps it chosen."]
                ],
                handler: { await self.readScreen($0) }
            ),
            Tool(
                name: "list_windows",
                description: "macOS: the connected app's windows, with number, title and position, and which one has focus and which is chosen. Choose one with `read_screen` and `window`.",
                handler: { _ in await self.listWindows() }
            ),
            Tool(
                name: "bring_to_front",
                description: "macOS: brings one of the app's windows to the front and keeps it chosen; if it is on another desktop, switches to that desktop (what the user sees changes). Without `window`, the chosen or only one. Returns the screen. Works only if the user allowed it in Fingertip → Settings; otherwise fails with `bring_to_front_disabled`.",
                properties: [
                    "window": ["type": "integer", "description": "Window number from `list_windows`."]
                ],
                handler: { await self.bringToFront($0) }
            ),
            Tool(
                name: "wait_for",
                description: "Waits inside the server, without handing the turn back, for an element whose text, label or #identifier contains `text` (ignoring case and accents), and returns the screen as soon as it appears. Checks every ~0.25 s. With `tap: true` it taps it on the spot: the way to catch something short-lived, like an approval card. With `gone: true` it waits for it to disappear (e.g. a «Working…»). If several match, an exact match wins and, among those, a button.",
                properties: [
                    "text": ["type": "string"],
                    "tap": ["type": "boolean", "description": "Tap it as soon as it appears."],
                    "gone": ["type": "boolean", "description": "Wait for it to disappear instead of appear."],
                    "timeout": ["type": "number", "description": "Seconds; 30 by default, 120 at most."]
                ],
                required: ["text"],
                handler: { await self.waitFor($0) }
            ),
            Tool(
                name: "tap",
                description: "Taps an element by its alias `@L:N` (preferred) or by coordinates `x`,`y` in the reading's space (frames come in `read_screen`). It re-reads the screen before tapping: if anything up to that element changed, it does not tap and returns the new screen to choose again. Returns what changed on screen. On a text field, a tap gives it focus: then use `type_text`. On macOS, tapping a pop-up opens its menu and the reading lists its items in the «Menú» region (`Mode › Scientific`); tapping one picks it, and tapping the pop-up again closes it. The «Delivery» line says what was tried and what was verified: `no effect` means the app took the action and nothing changed.",
                properties: [
                    "alias": ["type": "string", "description": "The full alias, as it appears in the reading: `12:5` is element 5 of reading 12."],
                    "x": ["type": "number"],
                    "y": ["type": "number"]
                ],
                handler: { await self.tap($0) }
            ),
            Tool(
                name: "select",
                description: "macOS: opens the menu of a pop-up or menu button (`alias`), picks the item `option` (ignoring case and accents) and reads the control back. If there is no such item, it closes the menu and lists the options. If a menu is already open, it refuses with `menu_already_open`.",
                properties: [
                    "alias": ["type": "string", "description": "The control's full alias, `12:5`."],
                    "option": ["type": "string", "description": "The menu item's text."]
                ],
                required: ["alias", "option"],
                handler: { await self.select($0) }
            ),
            Tool(
                name: "set_value",
                description: "macOS: writes a control's value in one go, without typing: text in a field, a date in a date picker (`yyyy-MM-dd HH:mm`, `yyyy-MM-dd` or `HH:mm`, local time), a number in a slider. Reads the value back; if it did not change, fails with `no_effect`. A read-only element gives `not_settable`.",
                properties: [
                    "alias": ["type": "string", "description": "The control's full alias, `12:5`."],
                    "value": ["type": "string"]
                ],
                required: ["alias", "value"],
                handler: { await self.setValue($0) }
            ),
            Tool(
                name: "toggle",
                description: "macOS: flips a checkbox, radio button or switch and checks that it flipped (AXPress, then AXValue, then a real click).",
                properties: ["alias": ["type": "string", "description": "The control's full alias, `12:5`."]],
                required: ["alias"],
                handler: { await self.toggle($0) }
            ),
            Tool(
                name: "type_text",
                description: "Types into the focused field (tap it first). The simulator only has a US keyboard: no accents, ñ or symbols outside ASCII. On macOS any text works.",
                properties: ["text": ["type": "string"]],
                required: ["text"],
                handler: { await self.typeText($0) }
            ),
            Tool(
                name: "erase_text",
                description: "Deletes `count` characters from the end of the focused field.",
                properties: ["count": ["type": "integer", "minimum": 1]],
                required: ["count"],
                handler: { await self.eraseText($0) }
            ),
            Tool(
                name: "submit",
                description: "Presses Return in the focused field without leaving it: submits the form (its `onSubmit`). Tap the field first.",
                handler: { _ in await self.perform(.submit) }
            ),
            Tool(
                name: "scroll",
                description: "Scrolls the content. `down` shows what is further down, `up` what is further up. A reading only has what is visible: if what you are looking for is not there, scroll.",
                properties: ["direction": ["type": "string", "enum": ["down", "up"]]],
                required: ["direction"],
                handler: { await self.scroll($0) }
            ),
            Tool(
                name: "swipe",
                description: "Swipes between two points in the reading's space (carousels, dismiss gestures). For plain vertical scrolling, `scroll` is simpler.",
                properties: [
                    "from_x": ["type": "number"], "from_y": ["type": "number"],
                    "to_x": ["type": "number"], "to_y": ["type": "number"]
                ],
                required: ["from_x", "from_y", "to_x", "to_y"],
                handler: { await self.swipe($0) }
            ),
            Tool(
                name: "press_button",
                description: "A simulator hardware button. Not available on macOS.",
                properties: ["button": ["type": "string", "enum": ["home", "lock", "side-button", "siri", "apple-pay"]]],
                required: ["button"],
                handler: { await self.pressButton($0) }
            ),
            Tool(
                name: "screenshot",
                description: "Captures the simulator screen or the app's window. Returns the reduced image and the path to the full PNG. Use it to check visuals (layout, colors, images); to know what is there and what to tap, `read_screen` is cheaper.",
                handler: { _ in await self.screenshot() }
            ),
            Tool(
                name: "start_recording",
                description: "Starts recording a video (.mov, no audio) of the simulator or the app's window. One recording at a time; later actions (tap, scroll…) end up in the video. End it with `stop_recording`.",
                handler: { _ in await self.startRecording() }
            ),
            Tool(
                name: "stop_recording",
                description: "Ends the current recording and returns the path to the .mov. Disconnecting or closing the server with a recording open also closes the file.",
                handler: { _ in await self.stopRecording() }
            ),
            Tool(
                name: "relaunch_app",
                description: "Kills the app, opens it again and waits for its screen to be ready (up to 15 s). Use it to start each test from the initial screen. A macOS app running under the Xcode debugger is not relaunched.",
                properties: ["bundle_id": ["type": "string"]],
                required: ["bundle_id"],
                handler: { await self.relaunchApp($0) }
            ),
            Tool(
                name: "terminate_app",
                description: "Force-quits the app.",
                properties: ["bundle_id": ["type": "string"]],
                required: ["bundle_id"],
                handler: { await self.terminateApp($0) }
            ),
            Tool(
                name: "run_instruction",
                description: "Delegates a whole instruction to Jev (TypeSafe System One): it chooses and runs steps until it judges the instruction done, runs out of confidence (`needs_user`) or reaches 10 steps. With `bundle_id`, relaunches the app first. Returns the result, the steps and the path to the JSONL log with screenshots. Needs TYPESAFE_API_KEY in the server's environment.",
                properties: [
                    "instruction": ["type": "string", "description": "What to do, in natural language. Text to type goes in double quotes."],
                    "bundle_id": ["type": "string", "description": "App under test; empty starts from wherever the device is."]
                ],
                required: ["instruction"],
                handler: { await self.runInstruction($0) }
            ),
            Tool(
                name: "end_test",
                description: "Closes the test opened with `connect(test:)` with its verdict: ends the video and returns the folder. A new `connect` or the server closing also close it, without a verdict.",
                properties: [
                    "passed": ["type": "boolean", "description": "Whether the test passed."],
                    "notes": ["type": "string", "description": "What was tested and, if it failed, what was seen."]
                ],
                required: ["passed"],
                handler: { await self.endTest($0) }
            )
        ].map(traced)
    }

    // MARK: - Tests

    /// The call as is, plus a trace line when a test is open before or after it: the `connect`
    /// that opens a test is its first line, and the one that closes it is the last.
    private func traced(_ tool: Tool) -> Tool {
        var traced = tool
        traced.handler = { arguments in
            let open = self.test
            let started = ContinuousClock.now
            let result = await tool.handler(arguments)
            guard let test = self.test ?? open else { return result }
            let elapsed = ContinuousClock.now - started
            let screen = try? await self.inspector.driver?.screenshot()
            let text = result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let code = (result.structured?["error"] as? [String: Any])?["code"] as? String
            await test.record(tool: tool.name, arguments: arguments, text: text, errorCode: code,
                              milliseconds: Int(elapsed / .milliseconds(1)), screen: screen)
            return result
        }
        return traced
    }

    /// A failed folder or recording does not fail the `connect`: the device is already there.
    private func openTest(_ name: String, on target: Target) async -> String {
        let test: TestSession
        do {
            test = try TestSession(name: name, target: Self.describe(target))
        } catch {
            return "Couldn't create the test folder (\(error.localizedDescription)); continuing without recording the test."
        }
        self.test = test
        agent.runsDirectory = test.jevDirectory
        var lines = ["Test «\(name)» open: \(test.folder.path)"]
        do {
            try await inspector.driver?.startRecording(to: test.recording)
            lines.append("Recording the whole test. Close it with `end_test`.")
        } catch {
            let reason = fingertipError(error).errorDescription ?? "\(error)"
            test.recordingFailed(reason)
            lines.append("No video: \(reason)")
        }
        return lines.joined(separator: "\n")
    }

    /// Stops the test's video and writes its verdict; nil when no test is open.
    private func closeTest(passed: Bool?, notes: String?) async -> TestSession? {
        guard let test else { return nil }
        self.test = nil
        agent.runsDirectory = nil
        if let driver = inspector.driver {
            do {
                _ = try await driver.stopRecording()
            } catch RecordingError.notRecording {
                // It never started: `test.json` already says why.
            } catch {
                test.recordingFailed(fingertipError(error).errorDescription ?? "\(error)")
            }
        }
        test.finish(passed: passed, notes: notes)
        return test
    }

    private func endTest(_ arguments: [String: Any]) async -> ToolResult {
        guard test != nil else { return .error(ToolError.noTest) }
        guard let passed = arguments["passed"] as? Bool else { return .invalid("Missing `passed`: whether the test passed.") }
        guard let test = await closeTest(passed: passed, notes: arguments["notes"] as? String) else {
            return .error(ToolError.noTest)
        }
        let video = test.recordingError.map { "\nVideo: \($0)" } ?? ""
        return .text("Test «\(test.name)» closed: \(passed ? "passed" : "failed").\nFolder: \(test.folder.path)\(video)")
    }

    // MARK: - Status toast

    /// The call in a few words, for the Fingertip app's toast.
    func status(_ tool: String, _ arguments: [String: Any]) -> String {
        func quoted(_ text: String) -> String {
            "«\(text.count > 40 ? text.prefix(39) + "…" : text)»"
        }
        let text = arguments["text"] as? String ?? ""
        switch tool {
        case "list_targets": return "Looking for devices"
        case "connect": return "Connecting to \(arguments["bundle_id"] as? String ?? arguments["udid"] as? String ?? "a device")"
        case "read_screen": return "Reading the screen"
        case "wait_for": return (arguments["gone"] as? Bool ?? false) ? "Waiting for \(quoted(text)) to go" : "Waiting for \(quoted(text))"
        case "tap": return "Tapping \(tapTarget(arguments))"
        case "select": return "Choosing \(quoted(arguments["option"] as? String ?? "")) in \(tapTarget(arguments))"
        // The value may be a password, like typed text.
        case "set_value": return "Setting the value of \(tapTarget(arguments))"
        case "toggle": return "Toggling \(tapTarget(arguments))"
        case "list_windows": return "Listing windows"
        case "bring_to_front": return "Bringing the window to the front"
        // Typed text and instructions may carry a password: the toast is on screen and in recordings.
        case "type_text": return "Typing \(text.count) characters"
        case "erase_text": return "Deleting \(arguments["count"] as? Int ?? 0) characters"
        case "submit": return "Return"
        case "scroll": return (arguments["direction"] as? String) == "up" ? "Scrolling up" : "Scrolling down"
        case "swipe": return "Swiping"
        case "press_button": return "Button \(arguments["button"] as? String ?? "")"
        case "screenshot": return "Taking a screenshot"
        case "start_recording": return "Starting to record"
        case "stop_recording": return "Stopping the recording"
        case "relaunch_app": return "Relaunching \(arguments["bundle_id"] as? String ?? "the app")"
        case "terminate_app": return "Quitting \(arguments["bundle_id"] as? String ?? "the app")"
        case "run_instruction": return "Jev: running an instruction"
        case "end_test": return (arguments["passed"] as? Bool ?? false) ? "Test closed: passed" : "Test closed: failed"
        default: return tool
        }
    }

    /// The element's caption when the alias is from the current reading.
    private func tapTarget(_ arguments: [String: Any]) -> String {
        guard let alias = arguments["alias"] as? String else { return "a point" }
        let parts = alias.trimmingCharacters(in: CharacterSet(charactersIn: "@")).split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, parts[0] == inspector.reading,
           let element = inspector.elements.first(where: { $0.alias == parts[1] }) {
            return "«\(element.caption)»"
        }
        return "@\(alias)"
    }

    // MARK: - Blocked apps

    /// The list lives in `BlockedApps`; the user edits it in the app's Security pane.
    /// God mode is decided when registering the server, not by Claude: a tool argument
    /// could be passed by the same injected instruction the block is meant to stop.
    private static let isUnrestricted = ProcessInfo.processInfo.environment["FINGERTIP_UNRESTRICTED"] == "1"

    /// The apps the user allowed, read once at launch, like god mode. Through an app that is
    /// not blocked (a text editor), an injected instruction could edit the settings file; read
    /// live, that would unblock a terminal within the same session. Read at launch, it takes a
    /// restart (`/mcp`), as editing the registration does.
    private static let atLaunch = FingertipSettings.load()

    /// Blocks added since launch apply on the next check: that direction opens nothing. The
    /// ones present at launch are kept even if the file loses them (edited, or no longer
    /// decodes): removing a block, like allowing an app, takes a restart.
    private static func isBlocked(_ bundleID: String, settings: FingertipSettings = .load()) -> Bool {
        var settings = settings
        settings.unblockedAppIDs = atLaunch.unblockedAppIDs
        settings.extraBlockedAppIDs = atLaunch.extraBlockedApps + settings.extraBlockedApps
        return BlockedApps.isBlocked(bundleID, unrestricted: isUnrestricted, settings: settings)
    }

    private static func blockedError(_ bundleID: String) -> ToolResult {
        .error(ToolError.blockedApp("""
        \(bundleID) is blocked: typing into it can run commands or expose secrets. \
        Only the user can unblock it, in Fingertip → Settings → Security or by registering the server with `-e FINGERTIP_UNRESTRICTED=1`.
        """))
    }

    // MARK: - Device

    private func listTargets() async -> ToolResult {
        var lines: [String] = ["Simulators:"]
        var booted: Set<String>?
        do {
            let devices = try await simctl.listDevices()
            lines += devices.map { "  \($0.name) — \($0.runtime) — \($0.udid)\($0.isBooted ? " — booted" : "")" }
            booted = Set(devices.filter(\.isBooted).map(\.udid))
        } catch {
            lines.append("  (couldn't list them: \(Self.describe(error)))")
        }
        lines.append("")
        lines.append("Running macOS apps:")
        let apps = MacApp.running()
        let settings = FingertipSettings.load()
        lines += apps.map { "  \($0.name) — \($0.bundleID) — \($0.bundleURL.path)\(Self.isBlocked($0.bundleID, settings: settings) ? " — blocked" : "")" }
        if let target {
            // The connection doesn't notice the app quit or the simulator shut down:
            // saying it here keeps anyone from thinking it still points at something alive.
            let alive = switch target {
            case .simulator(let udid): booted?.contains(udid) ?? true
            case .mac(let app): apps.contains(app)
            }
            lines += ["", alive
                ? "Connected to: \(Self.describe(target))"
                : "Connected to: \(Self.describe(target)) — no longer running; use `connect`."]
        }
        return .text(lines.joined(separator: "\n"))
    }

    private func connect(_ arguments: [String: Any]) async -> ToolResult {
        let udid = arguments["udid"] as? String
        let bundleID = arguments["bundle_id"] as? String
        guard (udid == nil) != (bundleID == nil) else {
            return .invalid("Pass either `udid` (simulator) or `bundle_id` (macOS app), not both.")
        }

        let target: Target
        if let udid {
            do {
                try await simctl.boot(udid: udid)
            } catch {
                return .error(fingertipError(error))
            }
            target = .simulator(udid: udid)
        } else {
            if Self.isBlocked(bundleID!) { return Self.blockedError(bundleID!) }
            guard let app = Self.macApp(bundleID: bundleID!, path: arguments["app_path"] as? String) else {
                return .error(ToolError.appNotFound("Couldn't find \(bundleID!) running or installed (or `app_path` is a different app)."))
            }
            // The resolved app is checked too: what opens is the app, not the requested text.
            if Self.isBlocked(app.bundleID) { return Self.blockedError(app.bundleID) }
            let running = MacApp.running().contains(app)
            target = .mac(app)
            if !running {
                do {
                    try await target.makeDriver().launch(bundleID: app.bundleID)
                } catch {
                    return .error(fingertipError(error))
                }
            }
        }
        // A new `connect` closes the open test whether or not it opens another.
        let closed = await closeTest(passed: nil, notes: nil)
        var result = await connect(to: target)
        var notes: [String] = []
        if let closed { notes.append("Closed test «\(closed.name)» without a verdict: \(closed.folder.path)") }
        if let name = (arguments["test"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty, inspector.connectionState == .ready {
            notes.append(await openTest(name, on: target))
        }
        if !notes.isEmpty, let text = result.content.first?["text"] as? String {
            result.content[0]["text"] = notes.joined(separator: "\n") + "\n\n" + text
        }
        return result
    }

    private func connect(to target: Target) async -> ToolResult {
        // Switching devices closes a recording in progress; say so, or the agent loses the file.
        let closed = inspector.driver != nil ? await inspector.disconnect() : nil
        let closedNote = closed.map { "Closed the recording in progress when switching devices: \($0.path)\n\n" } ?? ""
        // An agent must say which window it means: "the focused one" is whatever the user clicked last.
        await inspector.connect(target)
        guard inspector.connectionState == .ready else {
            return .error(inspector.failure ?? ToolError.notConnected("Couldn't connect."))
        }
        self.target = target
        focusRegion = nil
        shown = nil
        let connected = "\(closedNote)Connected to \(Self.describe(target)) via \(inspector.driver?.name ?? "?")."
        // Connected, but nothing read yet: the error names the windows to choose from.
        if let failure = inspector.failure { return .error(failure, appending: connected) }
        return .text("\(connected)\n\n\(outline())")
    }

    /// A running copy wins over an installed one: it is the one the user is looking at.
    /// Between two running copies the path decides; without a path, the first.
    private static func macApp(bundleID: String, path: String?) -> MacApp? {
        // An .app is a directory: without the hint the URL has no trailing `/` and
        // doesn't equal `NSRunningApplication.bundleURL`, which has one.
        let wanted = path.map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
        if let running = MacApp.running().first(where: { $0.bundleID == bundleID && (wanted == nil || $0.bundleURL == wanted) }) {
            return running
        }
        guard let url = wanted ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        // `app_path` decides what opens: if it points at another app, it is refused
        // instead of launching that one disguised as the requested bundle id.
        guard let actual = Bundle(url: url)?.bundleIdentifier,
              actual.caseInsensitiveCompare(bundleID) == .orderedSame
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return MacApp(bundleID: actual, name: name, bundleURL: url.standardizedFileURL)
    }

    /// With exactly one booted simulator there is nothing to choose: the common case.
    private func ensureConnected() async -> ToolResult? {
        if inspector.driver != nil { return nil }
        let booted = ((try? await simctl.listDevices()) ?? []).filter(\.isBooted)
        guard booted.count == 1 else {
            return .error(ToolError.notConnected("No device connected and \(booted.count) simulators are booted: use `list_targets` and `connect`."))
        }
        let result = await connect(to: .simulator(udid: booted[0].udid))
        return result.isError ? result : nil
    }

    // MARK: - Screen

    private func readScreen(_ arguments: [String: Any]) async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        if let raw = arguments["window"] {
            guard let number = Self.int(raw) else { return .invalid("`window` is the number from `list_windows`.") }
            await inspector.chooseWindow(number: number)
        } else {
            await inspector.readScreen()
        }
        if let failure = inspector.failure { return .error(failure) }
        let skeleton = arguments["skeleton"] as? Bool ?? false
        if let region = arguments["region"] as? String, !region.isEmpty, !skeleton {
            guard inspector.regions.contains(region) else {
                return .invalid("There is no region «\(region)». There are: \(inspector.regions.map { "«\($0)»" }.joined(separator: ", ")).")
            }
            focusRegion = region
        } else {
            focusRegion = nil
        }
        return .text(outline(full: arguments["full"] as? Bool ?? false, skeleton: skeleton, whole: true))
    }

    /// Reads in a loop until the element appears (or disappears). Waiting here and not
    /// in the model is the whole point: a Claude turn takes seconds, a reading under
    /// 0.1 s on macOS and ~0.5 s on the simulator.
    private func waitFor(_ arguments: [String: Any]) async -> ToolResult {
        guard let query = arguments["text"] as? String, !query.isEmpty else { return .invalid("Missing `text`.") }
        let shouldTap = arguments["tap"] as? Bool ?? false
        let gone = arguments["gone"] as? Bool ?? false
        guard !(shouldTap && gone) else { return .invalid("`tap` and `gone` don't go together.") }
        let seconds = min(max(Self.double(arguments["timeout"]) ?? 30, 1), 120)
        if let failure = await ensureConnected() { return failure }

        let start = ContinuousClock.now
        let deadline = start + .seconds(seconds)
        while true {
            await inspector.readScreen()
            if let failure = inspector.failure { return .error(failure) }
            if !inspector.vanishedApps.isEmpty {
                return .error(ToolError.appVanished("The app stopped running while waiting for «\(query)»."), appending: outline())
            }
            let match = Self.match(query, in: inspector.elements, toTap: shouldTap)
            let waited = (ContinuousClock.now - start).components
            let elapsed = String(format: "%.1f", Double(waited.seconds) + Double(waited.attoseconds) / 1e18)

            if gone, match == nil {
                return .text("«\(query)» is gone (\(elapsed) s).\n\n\(outline())")
            }
            if !gone, let match {
                guard shouldTap else { return .text("«\(query)» appeared (\(elapsed) s).\n\n\(outline())") }
                await inspector.perform(match.tapAction)
                if let failure = inspector.failure { return .error(failure) }
                return .text("«\(query)» appeared (\(elapsed) s) and I tapped it: \(match.type) \"\(Self.clipped(match.caption))\".\n\n\(outline())")
            }
            guard ContinuousClock.now < deadline else {
                let what = gone ? "«\(query)» is still on screen" : "«\(query)» did not appear"
                return .error(ToolError.timedOut("\(what) after \(Int(seconds)) s."), appending: outline())
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Exact before partial and, when tied, a button before a text. To tap, a text
    /// that only *contains* the word doesn't count: «Approve» is often in the message
    /// body too, which exists before the card.
    private static func match(_ query: String, in elements: [UIElement], toTap: Bool = false) -> UIElement? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func fields(_ e: UIElement) -> [String] { [e.label, e.text, e.identifier].compactMap { $0 } }
        func isExact(_ e: UIElement) -> Bool { fields(e).contains { $0.compare(query, options: options) == .orderedSame } }
        func isProse(_ e: UIElement) -> Bool { ["StaticText", "TextView", "Image"].contains(e.type) }
        let hits = elements.filter { e in
            fields(e).contains { $0.range(of: query, options: options) != nil } && (!toTap || isExact(e) || !isProse(e))
        }
        func rank(_ e: UIElement) -> Int { (isExact(e) ? 0 : 2) + (e.type.contains("Button") ? 0 : 1) }
        return hits.min { rank($0) < rank($1) }
    }

    /// An element's line without its alias, and its region: what tells whether it changed.
    private struct ShownLine: Equatable {
        let region: String
        let body: String
    }

    /// Lines keyed by alias (`@N`), or by the line itself for an element without one.
    private struct Shown {
        let app: String?
        let reading: Int
        let lines: [String: ShownLine]
    }

    private func key(_ element: UIElement, _ body: String) -> String {
        element.alias.map { "@\($0)" } ?? "\(element.region)\n\(body)"
    }

    /// The same format as sim-use's outline, which is what reads best. After an action it
    /// lists only the elements that changed since the previous outline: three quarters of
    /// the tokens an agent spends on fingertip were whole screens, a fifth of them identical
    /// to the one before. `whole` (a `read_screen`) always lists everything. Only `whole`
    /// shows the frame of an element with an alias: frames were a third of those tokens,
    /// and a tap after an action goes by alias.
    private func outline(full: Bool = false, skeleton: Bool = false, whole: Bool = false) -> String {
        let size = inspector.screenSize
        var lines = ["App: \(inspector.appLabel ?? "?") (\(inspector.appPackage ?? "?"))  \(Int(size.width))x\(Int(size.height))  · reading \(inspector.reading)"]
        if !inspector.vanishedApps.isEmpty {
            lines.append("⚠ Stopped running since the previous reading (crash?): \(inspector.vanishedApps.joined(separator: ", "))")
        }
        if let focus = focusRegion, !inspector.regions.contains(focus) { focusRegion = nil }

        // Only a plain whole-screen outline is a base to compare with; a region or a skeleton isn't.
        let previous = shown
        var current: Shown?
        if !skeleton && focusRegion == nil {
            var shownLines: [String: ShownLine] = [:]
            for element in inspector.elements {
                let body = line(element, full: false, alias: false, frame: false)
                shownLines[key(element, body)] = ShownLine(region: element.region, body: body)
            }
            current = Shown(app: inspector.appPackage, reading: inspector.reading, lines: shownLines)
        }
        shown = current
        if !whole, let previous, let current, previous.app == current.app,
           let changes = changes(from: previous, to: current) {
            return (lines + changes).joined(separator: "\n")
        }

        for region in inspector.regions {
            let members = inspector.elements(in: region)
            if skeleton || (focusRegion != nil && region != focusRegion) {
                lines.append("[\(region)] \(members.count) elements")
            } else {
                lines.append("[\(region)]")
                lines += members.map { line($0, full: full, frame: whole) }
            }
        }
        if inspector.elements.isEmpty { lines.append("(no elements)") }
        if skeleton {
            lines.append("To see a region: `read_screen` with `region`.")
        } else if let focus = focusRegion {
            lines.append("Showing only «\(focus)»; `read_screen` without `region` goes back to the whole screen.")
        } else if inspector.elements.count > Self.denseThreshold {
            lines.append("Dense screen (\(inspector.elements.count) elements): `read_screen` with `skeleton: true` and then `region` costs less.")
        }
        return lines.joined(separator: "\n")
    }

    /// What changed between two outlines, or `nil` when most of it did and the whole screen reads better.
    private func changes(from previous: Shown, to current: Shown) -> [String]? {
        let gone = previous.lines.filter { current.lines[$0.key] == nil }
        let changed = current.lines.filter { previous.lines[$0.key] != $0.value }
        if changed.isEmpty && gone.isEmpty {
            return ["No changes since reading \(previous.reading)."]
        }
        guard 2 * (changed.count + gone.count) < current.lines.count else { return nil }
        var lines = ["Only what changed since reading \(previous.reading). Every other element is as listed then and keeps its number: use @\(current.reading):N. `read_screen` lists the whole screen, with frames."]
        for region in inspector.regions {
            let members = inspector.elements(in: region).filter { element in
                changed[key(element, line(element, full: false, alias: false, frame: false))] != nil
            }
            guard !members.isEmpty else { continue }
            lines.append("[\(region)]")
            lines += members.map { line($0, full: false, frame: false) }
        }
        let goneAliases = gone.keys.filter { $0.hasPrefix("@") }
            .compactMap { Int($0.dropFirst()) }.sorted()
        if !goneAliases.isEmpty {
            lines.append("Gone: " + goneAliases.map { "@\(previous.reading):\($0)" }.joined(separator: ", "))
        }
        lines += gone.filter { !$0.key.hasPrefix("@") }.map { "Gone: [\($0.value.region)] \($0.value.body)" }
        return lines
    }

    /// `frame: false` leaves out the frame of an element with an alias; one without an alias keeps it.
    /// An empty frame never goes out: menus measure 0x0 with the app behind, and are pressed through AX.
    private func line(_ element: UIElement, full: Bool, alias: Bool = true, frame: Bool = true) -> String {
        let show: (String) -> String = full ? { $0 } : { Self.clipped($0) }
        var parts = alias ? [element.alias.map { "@\(inspector.reading):\($0)" } ?? "--", element.type] : [element.type]
        if let label = element.label { parts.append("\"\(show(label))\"") }
        if let text = element.text { parts.append(element.label == nil ? "\"\(show(text))\"" : "= \"\(show(text))\"") }
        if let identifier = element.identifier { parts.append("#\(identifier)") }
        let b = element.bounds
        if (frame || element.alias == nil) && !b.isEmpty { parts.append("(\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height)))") }
        if !element.isEnabled { parts.append("[deshabilitado]") }
        if let checked = element.isChecked { parts.append(checked ? "[marcado]" : "[desmarcado]") }
        return " " + parts.joined(separator: " ")
    }

    /// One line and up to 100 characters. An action can return the whole screen, and
    /// a chat reply can be a page long: cut, it is still recognisable, and
    /// `read_screen` with `full` returns it whole when it has to be read.
    private static func clipped(_ text: String, limit: Int = 100) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        guard flat.count > limit else { return flat }
        return "\(flat.prefix(limit))… (\(text.count) characters)"
    }

    // MARK: - Windows

    private func listWindows() async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        guard case .mac(let app)? = target else { return .invalid("`list_windows` is for macOS apps: the simulator has a single screen.") }
        let windows: [WindowInfo]
        do {
            windows = try await inspector.listWindows()
        } catch {
            return .error(fingertipError(error))
        }
        guard !windows.isEmpty else { return .text("\(app.name) has no windows.") }
        var lines = ["Windows of \(app.name) (\(app.bundleID)):"]
        lines += windows.map { window in
            let f = window.frame
            var parts = ["  \(window.caption)", "(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))"]
            if window.isFocused { parts.append("[focused]") }
            if window.isChosen { parts.append("[chosen]") }
            if window.isMinimized { parts.append("[minimized]") }
            if window.isOnOtherSpace { parts.append("[on another desktop]") }
            return parts.joined(separator: "  ")
        }
        lines.append("Choose one with `read_screen` and `window: <number>`.")
        return .text(lines.joined(separator: "\n"))
    }

    private func bringToFront(_ arguments: [String: Any]) async -> ToolResult {
        guard FingertipSettings.load().bringToFrontEnabled else { return .error(ToolError.bringToFrontDisabled) }
        if let failure = await ensureConnected() { return failure }
        guard case .mac? = target else { return .invalid("`bring_to_front` is for macOS apps: the simulator has a single screen.") }
        var window: Int?
        if let raw = arguments["window"] {
            guard let number = Self.int(raw) else { return .invalid("`window` is the number from `list_windows`.") }
            window = number
        }
        await inspector.bringToFront(window: window)
        if let failure = inspector.failure { return .error(failure) }
        focusRegion = nil
        return .text(outline())
    }

    // MARK: - Actions

    private func tap(_ arguments: [String: Any]) async -> ToolResult {
        if let raw = arguments["alias"] {
            guard let (reading, alias) = Self.alias(raw) else {
                return .invalid("`alias` goes in full, as it appears in the reading: `12:5` is element 5 of reading 12.")
            }
            if let failure = await ensureConnected() { return failure }
            await inspector.tap(alias: alias, seenIn: reading)
            return finished("Tap @\(reading):\(alias)")
        }
        guard let x = Self.double(arguments["x"]), let y = Self.double(arguments["y"]) else {
            return .invalid("Pass `alias`, or `x` and `y`.")
        }
        return await perform(.tap(alias: nil, point: CGPoint(x: x, y: y)))
    }

    private func select(_ arguments: [String: Any]) async -> ToolResult {
        guard let option = arguments["option"] as? String, !option.isEmpty else { return .invalid("Missing `option`.") }
        return await act(arguments, caption: "Choose «\(option)»") { element in
            element.alias.map { .select(alias: $0, option: option) }
        }
    }

    private func setValue(_ arguments: [String: Any]) async -> ToolResult {
        guard let value = arguments["value"] as? String else { return .invalid("Missing `value`.") }
        return await act(arguments, caption: "Set the value") { element in
            element.alias.map { .setValue(alias: $0, value: value) }
        }
    }

    private func toggle(_ arguments: [String: Any]) async -> ToolResult {
        await act(arguments, caption: "Toggle") { element in
            element.alias.map { .toggle(alias: $0) }
        }
    }

    /// An action on `@reading:alias`, checked against that reading like `tap`.
    private func act(_ arguments: [String: Any], caption: String, _ build: @escaping (UIElement) -> DeviceAction?) async -> ToolResult {
        guard let (reading, alias) = Self.alias(arguments["alias"]) else {
            return .invalid("`alias` goes in full, as it appears in the reading: `12:5` is element 5 of reading 12.")
        }
        if let failure = await ensureConnected() { return failure }
        await inspector.act(onAlias: alias, seenIn: reading, build)
        return finished("\(caption) on @\(reading):\(alias)")
    }

    private func typeText(_ arguments: [String: Any]) async -> ToolResult {
        guard let text = arguments["text"] as? String, !text.isEmpty else { return .invalid("Missing `text`.") }
        return await perform(.inputText(text))
    }

    private func eraseText(_ arguments: [String: Any]) async -> ToolResult {
        guard let count = Self.int(arguments["count"]), count > 0 else { return .invalid("`count` must be greater than 0.") }
        return await perform(.eraseText(characters: count))
    }

    private func scroll(_ arguments: [String: Any]) async -> ToolResult {
        guard let direction = (arguments["direction"] as? String).flatMap(ScrollDirection.init(rawValue:)) else {
            return .invalid("`direction` is `down` or `up`.")
        }
        if let failure = await ensureConnected() { return failure }
        return await perform(.scroll(direction, screen: inspector.screenSize))
    }

    private func swipe(_ arguments: [String: Any]) async -> ToolResult {
        let values = ["from_x", "from_y", "to_x", "to_y"].compactMap { Self.double(arguments[$0]) }
        guard values.count == 4 else { return .invalid("Missing coordinates.") }
        return await perform(.swipe(from: CGPoint(x: values[0], y: values[1]), to: CGPoint(x: values[2], y: values[3])))
    }

    private func pressButton(_ arguments: [String: Any]) async -> ToolResult {
        guard let button = arguments["button"] as? String else { return .invalid("Missing `button`.") }
        return await perform(.pressButton(button))
    }

    /// `ScreenInspector.perform` waits for the screen to settle and re-reads it.
    private func perform(_ action: DeviceAction) async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        await inspector.perform(action)
        return finished(action.caption)
    }

    /// A failure worth retrying comes with the current screen, so the retry needs no extra read.
    /// The delivery line says what was tried and what was read back, so a press that did
    /// nothing is not mistaken for one that worked.
    private func finished(_ caption: String) -> ToolResult {
        if let failure = inspector.failure {
            return .error(failure, appending: failure.retrySafe ? outline() : nil)
        }
        let steps = inspector.lastDelivery
        guard !steps.isEmpty else { return .text("\(caption) → done.\n\n\(outline())") }
        // Text only: Claude Code shows `structuredContent` instead of the text when both come,
        // and the reply would lose the screen.
        return .text("\(caption) → done.\nDelivery: \(steps.map(\.caption).joined(separator: " → "))\n\n\(outline())")
    }

    private func screenshot() async -> ToolResult {
        if let failure = await ensureConnected() { return failure }
        guard let driver = inspector.driver else { return .error(ToolError.notConnected("No device connected.")) }
        let png: Data
        do {
            png = try await driver.screenshot()
        } catch {
            return .error(fingertipError(error))
        }

        // The folder chosen in the Fingertip app, read per call so a change applies without reconnecting.
        let directory = FingertipSettings.load().effectiveScreenshotsDirectory
        let file = Self.screenshotFile(in: directory)
        let saved: String
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: file, options: .withoutOverwriting)
            saved = "Full PNG: \(file.path)"
        } catch {
            saved = "Couldn't save the PNG in \(directory.path): \(error.localizedDescription)"
        }

        guard let jpeg = Self.reduced(png, maxSide: Self.inlineImageSide) else {
            return .text("Couldn't reduce the screenshot. \(saved)")
        }
        return ToolResult(content: [
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
            ["type": "text", "text": saved]
        ])
    }

    // MARK: - Recording

    private func startRecording() async -> ToolResult {
        if let test { return .error(ToolError.testInProgress("Test «\(test.name)» is already being recorded whole to \(test.recording.path); its video is closed with `end_test`.")) }
        if let failure = await ensureConnected() { return failure }
        guard let driver = inspector.driver else { return .error(ToolError.notConnected("No device connected.")) }
        // The folder chosen in the Fingertip app, read per call like the screenshots one.
        let directory = FingertipSettings.load().effectiveRecordingsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = Self.recordingFile(in: directory)
            try await driver.startRecording(to: file)
            return .text("Recording → \(file.path)\nEnd it with `stop_recording`.")
        } catch {
            return .error(fingertipError(error))
        }
    }

    private func stopRecording() async -> ToolResult {
        if let test { return .error(ToolError.testInProgress("The video of test «\(test.name)» is closed with `end_test`, not `stop_recording`.")) }
        // No `ensureConnected`: stopping must not connect to anything.
        guard let driver = inspector.driver else { return .error(RecordingError.notRecording) }
        do {
            let file = try await driver.stopRecording()
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            return .text("Recording saved: \(file.path) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
        } catch {
            return .error(fingertipError(error))
        }
    }

    /// `fingertip-2026-11-01-12.30.05.123.mov`, with the same collision rule as the screenshots.
    private static func recordingFile(in directory: URL) -> URL {
        let stem = "fingertip-\(screenshotFormatter.string(from: .now))"
        var file = directory.appending(path: "\(stem).mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "\(stem)-\(suffix).mov")
            suffix += 1
        }
        return file
    }

    private static let screenshotFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH.mm.ss.SSS"
        return formatter
    }()

    /// `fingertip-2026-11-01-12.30.05.123.png`: sorts by time and reads well in a user's folder.
    /// The same name can come back (the hour repeated when clocks go back), so a taken one gets
    /// a `-2`, `-3`… instead of overwriting an earlier capture.
    private static func screenshotFile(in directory: URL) -> URL {
        let stem = "fingertip-\(screenshotFormatter.string(from: .now))"
        var file = directory.appending(path: "\(stem).png")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = directory.appending(path: "\(stem)-\(suffix).png")
            suffix += 1
        }
        return file
    }

    private static func reduced(_ png: Data, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Lifecycle

    private func relaunchApp(_ arguments: [String: Any]) async -> ToolResult {
        guard let bundleID = arguments["bundle_id"] as? String, !bundleID.isEmpty else { return .invalid("Missing `bundle_id`.") }
        if Self.isBlocked(bundleID) { return Self.blockedError(bundleID) }
        if let failure = await ensureConnected() { return failure }
        guard await inspector.relaunch(bundleID) else {
            return .error(inspector.failure ?? UnexpectedError(message: "Couldn't relaunch \(bundleID)."))
        }
        return .text("\(bundleID) relaunched.\n\n\(outline())")
    }

    private func terminateApp(_ arguments: [String: Any]) async -> ToolResult {
        guard let bundleID = arguments["bundle_id"] as? String, !bundleID.isEmpty else { return .invalid("Missing `bundle_id`.") }
        if Self.isBlocked(bundleID) { return Self.blockedError(bundleID) }
        if let failure = await ensureConnected() { return failure }
        do {
            try await inspector.driver?.terminate(bundleID: bundleID)
        } catch {
            return .error(fingertipError(error))
        }
        return .text("\(bundleID) quit.")
    }

    // MARK: - Jev

    private func runInstruction(_ arguments: [String: Any]) async -> ToolResult {
        guard let instruction = arguments["instruction"] as? String, !instruction.isEmpty else {
            return .invalid("Missing `instruction`.")
        }
        let bundleID = arguments["bundle_id"] as? String ?? ""
        if Self.isBlocked(bundleID) { return Self.blockedError(bundleID) }
        if let failure = await ensureConnected() { return failure }
        agent.instruction = instruction
        agent.bundleID = bundleID
        guard agent.canStep else { return .error(inspector.failure ?? ToolError.notConnected("The device is not ready.")) }
        await agent.run()

        let result = switch agent.outcome {
        case .goalReached: "goal_reached"
        case .needsUser: "needs_user"
        case .acted, .screenChanged, .none: agent.failure == nil ? "stopped" : "error"
        }
        var lines = ["Result: \(result)"]
        if let failure = agent.failure {
            lines.append("Error \(failure.code) · retry_safe: \(failure.retrySafe)\n\(failure.errorDescription ?? "")")
        }
        lines.append("Steps:")
        lines += agent.history.isEmpty ? ["  (ninguno)"] : agent.history.enumerated().map { "  \($0.offset + 1). \($0.element)" }
        if let decision = agent.decision {
            lines.append(String(format: "Last decision: confidence %.2f, instruction done %.2f", decision.confidence, decision.goalReached))
            if agent.heldForRisk, let risk = decision.risk {
                lines.append(String(format: "Stopped: the step looks destructive (risk %.2f) and the confidence %.2f is below %.2f. Confirm it yourself before tapping.", risk, decision.confidence, JevAgent.destructiveConfidence))
            }
            if case .needsUser = agent.outcome {
                lines.append("Options Jev weighed:")
                lines += decision.ranked.prefix(5).map { option in
                    let caption = option.element.map { "@\($0.alias.map(String.init) ?? "-") \($0.type) \"\($0.caption)\"" } ?? "(ninguno / scroll)"
                    return String(format: "  %.2f  %@", option.probability, caption)
                }
            }
        }
        if let path = agent.logPath { lines.append("Log: \(path)") }
        lines += ["", outline()]
        let text = lines.joined(separator: "\n")
        // Structured content only on an error: on a success Claude Code shows it instead of the
        // text, and the steps and the screen would be lost.
        guard result == "error" else {
            var reply = ToolResult.text(text)
            reply.outcome = result
            return reply
        }
        var structured: [String: Any] = ["result": result]
        if let failure = agent.failure {
            structured["error"] = ["code": failure.code, "retry_safe": failure.retrySafe, "message": failure.errorDescription ?? ""]
        }
        return ToolResult(content: [["type": "text", "text": text]], isError: true, structured: structured, outcome: result)
    }

    // MARK: - Utilities

    private static func describe(_ target: Target) -> String {
        switch target {
        case .simulator(let udid): "simulator \(udid)"
        case .mac(let app): "\(app.name) (\(app.bundleID), \(app.bundleURL.path))"
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// `12:5` or `@12:5`. A bare `5` is rejected: without the reading it cannot be checked.
    private static func alias(_ value: Any?) -> (reading: Int, alias: Int)? {
        guard let text = value as? String else { return nil }
        let parts = text.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).split(separator: ":")
        guard parts.count == 2, let reading = Int(parts[0]), let alias = Int(parts[1]) else { return nil }
        return (reading, alias)
    }

    /// JSONSerialization yields NSNumber: an integer may arrive as 3 or 3.0.
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
    }

    private static func double(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
}
