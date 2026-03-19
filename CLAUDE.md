# Remote Claude

A web-based mobile interface for Claude Code, accessible from a phone via Tailscale. Includes a macOS menu bar app for server management.

## Project Structure

```
~/projects/remote-claude/
  server.js              # Node.js server (Express + WebSocket + node-pty)
  public/
    index.html           # Frontend — project browser + terminal UI
    app.js               # Frontend logic — WebSocket, xterm.js, Gemini voice, touch
    audio-worklet-processor.js  # AudioWorklet — mic capture, downsample to 16kHz PCM16
  remote-claude          # CLI management script (start/stop/status/logs)
  macos-app/
    RemoteClaude.swift   # macOS menu bar app source
  certs/
    cert.pem / key.pem   # Self-signed HTTPS cert (for Tailscale IP YOUR_TAILSCALE_IP)
  remote-claude.log      # Runtime log file
  remote-claude.pid      # PID file for running server
  package.json           # Dependencies: express, ws, node-pty
  ~/.gemini-api-key      # Gemini API key (not in repo)
```

## Architecture

### Server (`server.js`)
- HTTPS server on port **3456** (falls back to HTTP if no certs)
- Serves static files from `public/`
- **Persistent PTY sessions** — PTYs survive WebSocket disconnects (phone standby):
  - `start` message → reattaches to existing PTY or spawns new `claude` via node-pty
  - `input` message → writes to PTY stdin
  - `resize` message → resizes PTY
  - `output` message → sends PTY stdout to all connected listeners
  - 5-minute grace period before killing orphaned PTYs
  - 50KB replay buffer — reconnecting clients see recent output
- API endpoints:
  - `GET /api/projects` — scans `~/projects/` recursively, returns folder/project tree
  - `GET /api/status` — returns uptime, connections, message count
  - `POST /api/gemini-token` — returns Gemini API key (Tailscale-only, not public)
- Project detection: checks for `.git`, `CLAUDE.md`, `package.json`, `CMakeLists.txt`, `build.gradle`, `build.gradle.kts`, `Cargo.toml`, `go.mod`, `Makefile`
- Structured logging with levels: INFO, CONN, DISC, START, WARN, ERROR, FATAL

### Frontend (`public/index.html` + `public/app.js`)
- **Screen 1**: Project browser — folders expand, projects open Claude sessions
- **Screen 2**: Terminal (xterm.js) with control bar:
  - Arrow keys (up/down/left/right), Enter, Mode (Shift+Tab), Gemini Voice
  - Touch scrolling with momentum/flick
  - Auto-reconnect WebSocket on background→foreground (reattaches to existing PTY)
- **Gemini Voice** — see Gemini Live Voice Assistant section below

### macOS App (`macos-app/RemoteClaude.swift`)
- Menu bar app (no Dock icon, `LSUIElement = true`)
- Shows server status with mic icon (filled = running)
- Start/Stop server, Copy Phone URL, Open in Browser, Show Logs
- Log viewer window with color-coded entries
- Compiled with: `swiftc -O -o macos-app/RemoteClaude macos-app/RemoteClaude.swift -framework Cocoa`
- Installed at: `~/Applications/Remote Claude.app`
- Uses full path `/usr/local/bin/node` (NOT `env node` — macOS apps don't have shell PATH)

### CLI (`remote-claude` script)
- Symlinked from `~/.local/bin/remote-claude`
- Commands: `start`, `start-bg`, `stop`, `restart`, `status`, `logs`, `help`

## Gemini Live Voice Assistant

Gemini acts as an intelligent voice intermediary between you and Claude Code.
Instead of raw speech-to-text, Gemini understands your intent and executes
terminal actions via function calling.

### How It Works

```
                          Tailscale (private network)
  +----------+    wss     +-------------+    wss     +------------------+
  |  Phone   |<---------->|   Server    |            | Google Gemini    |
  |  Browser |  terminal  |  server.js  |            | Live API         |
  +----------+  I/O       +------+------+            +------------------+
       |                         |                          ^    |
       |    voice (mic audio)    |                          |    |
       +-------------------------------------------------------->|
       |                         |     PCM16 @ 16kHz        |    |
       |                         |     base64 via WS        |    |
       |<--------------------------------------------------------+
       |    Gemini audio response (PCM16 @ 24kHz)           |    |
       |                         |                          |    |
       |    function calls       |                          |    |
       |    (send_text, approve) |                          |    |
       |<------------------------|<----- toolCall ----------|    |
       |    terminal input       |                               |
       +------------------------>|                               |
              sendInput()        |  pty.write()                  |
                                 +-----> Claude Code             |
                                 |                               |
                                 |  terminal output              |
                                 +------- clientContent -------->|
                                    (debounced, stripped,         |
                                     truncated to 4KB)           |
```

### Voice Flow (step by step)

```
  You say          Gemini understands       Action
  ──────────       ─────────────────        ──────────────────────
  "approve that"   intent: approve     -->  sends y + Enter to PTY
  "create tests"   intent: send text   -->  types "create tests" + Enter
  "option 2"       intent: select #2   -->  sends 2 + Enter to PTY
  "no"             intent: reject      -->  sends n + Enter to PTY
  "switch mode"    intent: cycle mode  -->  sends Shift+Tab to PTY
```

### Terminal Output Summarization

```
  Claude output (500 lines)
        |
        v
  stripAnsi() --> debounce 1.5s --> truncate >4KB (head+tail)
        |
        v
  Send as clientContent to Gemini
        |
        v
  Gemini decides:
    - Summarize: "Done -- created 3 test files, all passing"
    - Alert:     "Claude is asking for approval to edit main.rs"
    - Silent:    (progress bar, trivial output -- says nothing)
```

### Gemini Connection Lifecycle

```
  Tap mic button
       |
       v
  [idle] ---> POST /api/gemini-token ---> [connecting]
                                               |
       Open WebSocket to Gemini                |
       wss://generativelanguage.googleapis.com/ws/...?key=API_KEY
                                               |
       Send setup { model, tools, config }     |
                                               v
       Receive { setupComplete }          [active] (green pulse)
                                               |
       Start AudioWorklet mic capture          |
       Stream PCM16 @ 16kHz to Gemini          |
                                               |
       ~~~~ 9 minutes pass ~~~~                |
                                               v
       Auto-renew: disconnect + reconnect [connecting] -> [active]
                                               |
       Tap mic again or disconnect             |
                                               v
       Close WebSocket, stop mic          [idle]
```

### Button States

```
  State        Color     Animation       Meaning
  ─────        ─────     ─────────       ───────
  idle         dark      none            not connected
  connecting   grey      slow pulse      getting token / connecting
  active       green     medium pulse    listening for speech
  speaking     purple    fast pulse      Gemini is talking
```

### Audio Pipeline

```
  Mic (48kHz native)
       |
       v
  AudioWorklet (audio-worklet-processor.js)
       |  downsample 48kHz -> 16kHz
       |  float32 -> Int16 PCM
       v
  Main thread
       |  Int16 -> base64
       v
  WebSocket to Gemini
       |  { realtimeInput: { mediaChunks: [{ mimeType, data }] } }
       v
  Gemini processes speech
       |
       v
  Response: inlineData (audio/pcm @ 24kHz)
       |  base64 -> Int16 -> float32
       v
  AudioContext (24kHz) -> speakers
```

### Mic Muting (echo prevention)

```
  You speak ---> Gemini starts responding
                      |
                 micMuted = true  (stop sending audio)
                      |
                 Gemini speaks / executes function calls
                      |
                 { turnComplete: true }
                      |
                 micMuted = false  (resume sending audio)
```

### PTY Persistence (phone standby)

```
  Phone active         Phone standby          Phone wakes up
  ────────────         ──────────────         ─────────────────
  Browser <--WS--> Server               Browser reconnects WS
                      |                        |
                   WS drops                 send { type: start }
                      |                        |
                   PTY stays alive!         Server finds existing PTY
                   (5-min grace)               |
                      |                     Replay 50KB of recent output
                   Buffers all output          |
                   from Claude              Client sees current state
```

### Function Calling Tools

| Tool              | Gemini calls when...                        | Sends to PTY  |
|-------------------|---------------------------------------------|---------------|
| `send_text(text)` | User gives an instruction to type           | `text` + `\r` |
| `send_special(k)` | User says "escape", "up", "tab", etc.       | escape seq     |
| `approve()`       | User says "yes", "approve", "go ahead"      | `y` + `\r`    |
| `reject()`        | User says "no", "reject", "cancel"          | `n` + `\r`    |
| `select_option(n)`| User says "option 1", "pick two"            | `n` + `\r`    |

### Debug Panel

Long-press the status bar (bottom of screen) to toggle the debug log panel.
Shows all Gemini messages, mic status, and connection events.
Has a "Copy All" button for sharing logs.

## Critical Things to Know

### Environment Issues (MUST handle)
- **CLAUDECODE env var**: MUST delete from env before spawning claude, or it refuses to start ("nested session" error)
- **PATH not available**: When running via nohup, macOS app, or launchd, the shell PATH is minimal. Always use full paths:
  - Node: `/usr/local/bin/node`
  - Claude: `~/.local/bin/claude`
- **node-pty spawn-helper**: The prebuilt binary at `node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper` MUST have execute permission (`chmod +x`). Without it, every `pty.spawn()` fails with `posix_spawnp failed`
- Claude is spawned via `/bin/zsh -l -c ~/.local/bin/claude` to get a login shell environment

### Server Stability (MUST handle)
- **PTY sessions are persistent**: PTYs live in `ptySessions` Map, survive WebSocket disconnects. Set `session.pty = null` and `session.exited = true` in the `onExit` handler
- **Wrap `pty.resize()` in try/catch**: Race condition between exit and resize
- **Wrap `pty.spawn()` in try/catch**: Send error message to client instead of crashing
- **Add `wss.on('error', () => {})` handler**: The WebSocketServer re-emits server errors; without a handler it crashes with unhandled error
- **EADDRINUSE**: The `remote-claude` script kills port 3456 before starting. The server also has `server.on('error')` for graceful handling
- **Grace period**: When all listeners disconnect, PTY stays alive 5 minutes. Reconnecting reattaches and replays buffered output

### HTTPS / Mobile Access
- Self-signed cert generated for Tailscale IP: `openssl req -x509 -newkey rsa:2048 ... -addext "subjectAltName=IP:YOUR_TAILSCALE_IP"`
- Phone must accept the cert warning in browser
- Required for: microphone access (getUserMedia needs HTTPS on non-localhost)
- WebSocket auto-detects `wss://` vs `ws://` based on page protocol

### Mobile UX
- Font size >= 16px on inputs to prevent iOS auto-zoom
- `touch-action: pan-y` on terminal container
- Custom touch scroll handler with momentum for flick scrolling
- `visibilitychange` listener to reconnect WebSocket when Chrome comes back from background
- `100dvh` for proper mobile viewport height

## Do NOT

- Do NOT use `env node` or bare `node` in the macOS app or any non-shell context — use `/usr/local/bin/node`
- Do NOT use `env claude` — use full path `~/.local/bin/claude`
- Do NOT forget to delete `CLAUDECODE` from the environment before spawning claude
- Do NOT remove the try/catch around `pty.resize()` — it will crash the server
- Do NOT remove `session.pty = null` from the `onExit` handler
- Do NOT kill PTYs on WebSocket disconnect — they must persist for phone standby reconnects
- Do NOT send Gemini API key over public networks — server only serves it over Tailscale
- Do NOT use the `audio` field in Gemini `realtimeInput` — use `mediaChunks` (the "deprecated" format still works, `audio` does not)
- Do NOT set `spawn-helper` permissions to non-executable
- Do NOT serve over plain HTTP if you want microphone to work on mobile
- Do NOT use `term.focus()` on mobile — it steals focus from the control buttons
- Do NOT add `LSUIElement = false` to the macOS app — it should stay menu-bar-only

## Building & Deploying

### Rebuild macOS app
```bash
cd ~/projects/remote-claude
swiftc -O -o macos-app/RemoteClaude macos-app/RemoteClaude.swift -framework Cocoa
# Then update the installed app:
cp macos-app/RemoteClaude ~/Applications/Remote\ Claude.app/Contents/MacOS/RemoteClaude
# Or rebuild installer:
pkgbuild --root ~/Applications/Remote\ Claude.app --identifier com.local.remote-claude --version 1.x --install-location "/Applications/Remote Claude.app" ~/Desktop/RemoteClaude.pkg
```

### Regenerate HTTPS cert (if Tailscale IP changes)
```bash
openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem -days 365 -nodes -subj "/CN=remote-claude" -addext "subjectAltName=IP:<NEW_IP>"
```

### After npm install / node upgrade
```bash
chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper
```

### Set up Gemini voice
```bash
# Get a key from https://aistudio.google.com
echo "YOUR_KEY" > ~/.gemini-api-key
remote-claude restart
```
