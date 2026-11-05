# fingertip

[![Made by deadcode labs](https://img.shields.io/badge/made_by-deadcode_labs-111111?style=for-the-badge&labelColor=111111)](https://github.com/deadcode-labs)
[![Release](https://img.shields.io/github/v/release/deadcode-labs/fingertip?style=for-the-badge&label=release&labelColor=1c1c1c&color=1f6fbf)](https://github.com/deadcode-labs/fingertip/releases/latest)
[![License](https://img.shields.io/github/license/deadcode-labs/fingertip?style=for-the-badge&labelColor=1c1c1c&color=4c9a1f)](LICENSE)

Lets an agent see and drive an **iOS simulator** or a **macOS app**: it reads the screen through Accessibility, then taps, types, scrolls and takes screenshots — no XCTest runner, no UI test target in the app under test.

It runs as **`fingertip-mcp`**, an MCP server, so Claude Code — or any other MCP client, like Codex — can do manual verification itself: open your app, walk a flow, check what is on screen. Its `run_instruction` tool hands a whole natural-language instruction to [Jev](https://docs.typesafe.ai) (TypeSafe's System One), which drives the device choosing each step from a closed set of on-screen elements.

## Requirements

- macOS 27 and Xcode 27 (Swift 6.2 or later)
- For simulators: [`sim-use`](https://github.com/lycorp-jp/sim-use) and a booted simulator

  ```bash
  brew tap lycorp-jp/tap && brew install lycorp-jp/tap/sim-use
  ```

- For macOS apps: **Accessibility** permission, and **Screen Recording** for screenshots. They are granted to the app that runs fingertip — for the MCP, the terminal running Claude Code (or the MCP client you use).

## Install

### With the Fingertip app

Download `Fingertip.dmg` from the [latest release](https://github.com/deadcode-labs/fingertip/releases/latest), drag Fingertip to Applications and open it. The first launch walks through setup: it checks Xcode and sim-use (and installs sim-use through Homebrew), registers the MCP in Claude Code and points at the Mac permissions. The app lives in the menu bar: in **Ajustes… → Claude Code → Instalar / actualizar** it registers the bundled `fingertip-mcp` in Claude Code at user scope. Then reconnect with `/mcp`. The app updates itself through Sparkle (menu bar → **Buscar actualizaciones…**, or on its own once a day); the update carries the bundled `fingertip-mcp`, so reconnect with `/mcp` after it.

While it runs, the app shows what the agent is doing: an edge indicator, a status toast, and a ghost pointer over the element a Mac action touches (your real cursor never moves).

### From source

```bash
git clone https://github.com/deadcode-labs/fingertip.git
cd fingertip
swift build -c release
claude mcp add --scope user fingertip -- "$PWD/.build/release/fingertip-mcp"
```

### In other MCP clients

fingertip is a plain stdio MCP server, so any client can launch it; the app only registers it in Claude Code, so other clients are set up by hand. In Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.fingertip]
command = "/Applications/Fingertip.app/Contents/Resources/fingertip-mcp"
```

Clients with an `mcpServers` JSON (Cursor, Claude Desktop, Gemini CLI) take the same command. What changes outside Claude Code is in [`docs/mcp.md`](docs/mcp.md#other-mcp-clients).

In Claude Code, registered at user scope it is available from the repo of whatever app you are testing. Then ask Claude things like *"relaunch the app on the simulator, log in with test@example.com and check that the inbox shows three messages"*.

| Tool | What it does |
|---|---|
| `list_targets`, `connect` | List booted simulators and running Mac apps; pick one (`udid` or `bundle_id`) |
| `read_screen` | The screen as a list of elements, each with an `@L:N` alias (reading L, element N); `skeleton` and `region` for dense screens |
| `tap`, `type_text`, `erase_text`, `submit` | Act on an element by alias (or coordinates) |
| `select`, `set_value`, `toggle` | macOS: pick a pop-up or menu item; set a field, date or slider; flip a checkbox or switch |
| `list_windows` | A Mac app's windows, to choose one with `read_screen` |
| `start_recording`, `stop_recording` | Record a `.mov` of the simulator or a Mac window |
| `scroll`, `swipe`, `press_button` | Move around; hardware buttons on the simulator |
| `wait_for` | Wait for text to appear or go away, optionally tapping it the moment it shows up |
| `screenshot` | Inline JPEG, full PNG saved to disk |
| `relaunch_app`, `terminate_app` | Start the app from a clean state |
| `run_instruction` | Hand a whole instruction to Jev (needs `TYPESAFE_API_KEY`); each run is logged as JSONL with screenshots in `~/Library/Application Support/flowforge-jev/runs/` |

Every action returns the new screen. An alias from an older reading is rejected if anything up to that element changed, instead of tapping whatever took its place. Errors come with a code and a `retry_safe` flag. With exactly one booted simulator, the first call connects to it.

After changing the package, rebuild in release and reconnect the server (`/mcp` in Claude Code).

### Safety

Everything fingertip reads off a screen reaches the model as text, so an instruction hidden in a web page or an email could try to steer it. By default the MCP refuses to drive terminals, editors with integrated terminals, other agents' apps (Claude, Codex, ChatGPT), automation tools and launchers, System Settings and password managers. Only you can lift that, in the app's Settings → Seguridad: allow single apps (and add others to block), or turn on "Modo dios" for all of them; either way, reconnect with `/mcp`. Without the app, register the server with the variable:

```bash
claude mcp add --scope user fingertip -e FINGERTIP_UNRESTRICTED=1 -- "$PWD/.build/release/fingertip-mcp"
```

## Limitations

- Simulator typing goes through a US keyboard: accented characters and other non-ASCII text are rejected.
- Mac screenshots only work for windows on the current Space; reading and acting work on any Space.
- iOS Simulator and macOS apps on the same Mac only — no physical devices, no Android.

## How it works

- [`docs/simulator.md`](docs/simulator.md) — `simctl` and `sim-use`, with measured behaviour
- [`docs/macos.md`](docs/macos.md) — the Accessibility API driver
- [`docs/mcp.md`](docs/mcp.md) — the MCP server's design
- [`docs/jev.md`](docs/jev.md) — how Jev decides each step

## License

MIT — see [`LICENSE`](LICENSE).
