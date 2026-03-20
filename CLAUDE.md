# Remote Claude

A web-based mobile interface for Claude Code, accessible from a phone via Tailscale. Includes a macOS menu bar app for server management.

## Project Structure

```
remote-claude/
├── server.js                  # HTTPS + WebSocket + node-pty server
├── public/
│   ├── index.html             # Project browser + terminal UI
│   ├── app.js                 # Frontend logic, Gemini voice, touch
│   └── audio-worklet-processor.js  # Mic capture, downsample to 16kHz
├── remote-claude              # CLI script (start/stop/status/logs)
├── macos-app/
│   └── RemoteClaude.swift     # Menu bar app source
├── certs/
│   ├── cert.pem               # Self-signed HTTPS cert
│   └── key.pem                # (for Tailscale IP)
├── package.json               # express, ws, node-pty
└── ~/.gemini-api-key          # Gemini API key (not in repo)
```

## Architecture

```
  ┌──────────┐         ┌──────────────┐         ┌──────────────┐
  │  Phone   │◄──wss──►│   Server     │         │ Google Gemini│
  │  Browser │         │  :3456       │         │ Live API     │
  └────┬─────┘         └──────┬───────┘         └──────┬───────┘
       │                      │                        │
       │  mic audio ─────────────────────────────────►│
       │◄──────────────────────────────── voice reply  │
       │                      │                        │
       │  function calls ◄────┤◄──── tool calls ───────┤
       │  (terminal input)    │                        │
       │─────────────────────►│                        │
       │                      ├──► Claude Code (PTY)   │
       │                      │◄── terminal output ────┤
       │◄── replay buffer ────┤    (debounced, 4KB)    │
       │                      │                        │
```

### Server (`server.js`)
- HTTPS on port **3456** (falls back to HTTP if no certs)
- Persistent PTY sessions — survive WebSocket disconnects (phone standby)
- 50KB replay buffer for reconnecting clients
- 5-minute grace period before killing orphaned PTYs
- API: `GET /api/projects`, `GET /api/status`, `POST /api/gemini-token`

### Frontend (`public/index.html` + `public/app.js`)
- **Screen 1**: Project browser with expandable folders
- **Screen 2**: xterm.js terminal with touch controls + Gemini voice

### macOS App (`macos-app/RemoteClaude.swift`)
- Menu bar app (`LSUIElement = true`, no Dock icon)
- Start/Stop server, Copy Phone URL, Show Logs
- Uses `/usr/local/bin/node` (macOS apps don't have shell PATH)

### CLI (`remote-claude` script)
- Commands: `start`, `start-bg`, `stop`, `restart`, `status`, `logs`

## Gemini Voice Assistant

Gemini is a voice bridge between you and Claude Code. It translates speech into terminal actions via function calling.

### Voice Commands

| You say              | Action                          |
|----------------------|---------------------------------|
| "create tests"       | `send_text("create tests")`     |
| "approve" / "yes"    | `approve()` → sends `y↵`       |
| "no" / "reject"      | `reject()` → sends `n↵`        |
| "option 2"           | `select_option(2)` → sends `2↵`|
| "escape" / "stop"    | `send_special("escape")`        |
| "switch mode"        | `send_special("shift_tab")`     |

### Output Summarization

Terminal output is stripped, debounced (2.5s), truncated to 4KB, and forwarded to Gemini as context. Gemini summarizes it, alerts on questions/approvals, or stays silent for trivial output.

### Connection Lifecycle

```
  Tap mic → fetch API key → open WebSocket → send setup
       → setupComplete → start mic capture → [active]
       → auto-renew at 9 min → tap mic to disconnect
```

### Button States

| State      | Color  | Animation   |
|------------|--------|-------------|
| idle       | dark   | none        |
| connecting | grey   | slow pulse  |
| active     | green  | medium pulse|
| speaking   | purple | fast pulse  |

### Audio Pipeline

```
  Mic 48kHz → AudioWorklet (downsample to 16kHz PCM16)
    → base64 → WebSocket → Gemini
    → response audio 24kHz PCM16 → speakers
```

Mic is muted while Gemini speaks (echo prevention), unmuted on `turnComplete`.

### Debug Panel

Long-press the status bar to toggle. Shows Gemini messages, mic status, connection events. "Copy All" button for sharing logs.

## Critical Rules

### Environment
- **Delete `CLAUDECODE` env var** before spawning claude (prevents "nested session" error)
- **Use full paths** — `/usr/local/bin/node`, `~/.local/bin/claude` (no `env`)
- **`spawn-helper` must be executable** — `chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper`
- Claude spawned via `/bin/zsh -l -c ~/.local/bin/claude` for login shell env

### Server Stability
- PTYs persist in `ptySessions` Map — set `session.pty = null` and `session.exited = true` in `onExit`
- Wrap `pty.resize()` and `pty.spawn()` in try/catch
- Add `wss.on('error', () => {})` handler (prevents crash on re-emitted errors)

### HTTPS / Mobile
- Self-signed cert for Tailscale IP (required for mic access on mobile)
- Font size ≥ 16px on inputs (prevents iOS auto-zoom)
- `visibilitychange` listener for WebSocket reconnect after backgrounding

### Do NOT
- Use `env node` or `env claude` — use full paths
- Remove try/catch around `pty.resize()` or `session.pty = null` from `onExit`
- Kill PTYs on WebSocket disconnect — they must persist for phone standby
- Use `audio` field in Gemini `realtimeInput` — use `mediaChunks`
- Use `term.focus()` on mobile — steals focus from controls
- Serve over plain HTTP if you want mic to work

## Building & Deploying

```bash
# Rebuild macOS app
swiftc -O -o macos-app/RemoteClaude macos-app/RemoteClaude.swift -framework Cocoa
cp macos-app/RemoteClaude ~/Applications/Remote\ Claude.app/Contents/MacOS/RemoteClaude

# Regenerate HTTPS cert (if Tailscale IP changes)
openssl req -x509 -newkey rsa:2048 -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes -subj "/CN=remote-claude" -addext "subjectAltName=IP:<NEW_IP>"

# After npm install / node upgrade
chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper

# Set up Gemini voice (key from https://aistudio.google.com)
echo "YOUR_KEY" > ~/.gemini-api-key
remote-claude restart
```
