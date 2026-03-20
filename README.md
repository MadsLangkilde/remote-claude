# Remote Claude

Control [Claude Code](https://docs.anthropic.com/en/docs/claude-code) from your phone. A mobile-first web terminal with persistent sessions, voice control via Gemini, and a macOS menu bar companion app.

```
  Phone                        Mac                         Google
 ┌─────────────┐    wss    ┌─────────────┐
 │ Terminal UI ├───────────┤ server.js   │
 │ Voice ctrl  │  :3456    │ node-pty    ├──── Claude Code
 │ Project nav │           │ Express+WS  │
 └──────┬──────┘           └─────────────┘
        │   mic audio                       ┌─────────────┐
        ├──────────────────────────────────►│ Gemini Live │
        │◄──────────────────────────────────┤ API         │
        │   voice + function calls          └─────────────┘
```

## Why

Claude Code is a terminal tool. It's great at your desk, but once you kick off a task and walk away, you have no way to check on it, approve tool use, or give follow-up instructions from your phone.

Remote Claude fixes that. Start a session on your Mac, then monitor and control it from anywhere — with full terminal access and hands-free voice control.

## Features

- **Project browser** — auto-detects projects under `~/projects/` by looking for `.git`, `package.json`, `Cargo.toml`, `go.mod`, `Makefile`, etc.
- **Session modes** — Resume (continue last conversation), New (fresh start), or YOLO (skip all permission prompts)
- **Persistent sessions** — PTY stays alive for 30 minutes when your phone goes to sleep. Reconnect and pick up exactly where you left off with full output replay
- **Voice control** — speak naturally and Gemini translates your intent into terminal actions
- **PWA** — add to your home screen for a fullscreen, app-like experience
- **macOS menu bar app** — start/stop server, show QR code, set API keys, view logs, onboarding guide
- **CLI management** — full command-line control for starting, stopping, and configuring the server

---

## How It Works

### The Server

The server (`server.js`) is an Express app on port 3456 that:

1. **Serves the frontend** — static files from `public/`
2. **Manages WebSocket connections** — each phone connects via WebSocket to interact with a PTY
3. **Maintains persistent PTY sessions** — Claude Code runs in `node-pty` pseudoterminals that survive WebSocket disconnects

When a phone connects and sends a `start` message, the server either **reattaches** to an existing PTY (replaying the last 100KB of output) or **spawns** a new Claude Code process. PTYs stay alive for 30 minutes after all connections drop. If the PTY exits while the phone was away, the server auto-resumes with `claude --continue`.

### The Frontend

The frontend (`public/index.html` + `public/app.js`) has three screens:

1. **Project Browser** — fetches the project tree from `/api/projects`
2. **Session Options** — choose Resume, New, or YOLO mode
3. **Terminal** — xterm.js with control buttons, custom touch scroll with momentum, and auto-reconnect on wake

---

## Voice Control

Instead of dumb speech-to-text, Google Gemini acts as an intelligent bridge between your voice and Claude Code. It translates speech into terminal actions via function calling and summarizes Claude's output back to you.

### Voice Commands

| You say | Gemini does |
|---|---|
| "create a login page" | `send_text("create a login page")` |
| "approve" / "yes" / "go ahead" | `approve()` — sends `y` + Enter |
| "no" / "reject" / "cancel" | `reject()` — sends `n` + Enter |
| "option 2" | `select_option(2)` — sends `2` + Enter |
| "escape" / "stop" | `send_special("escape")` |
| "switch mode" | `send_special("shift_tab")` |

Gemini cleans up your speech — removing filler words and false starts — and distills your intent into a concise prompt for Claude.

### Output Summarization

Terminal output is stripped of ANSI codes, debounced (2.5s), truncated to 4KB, and forwarded to Gemini. Gemini either summarizes the result, alerts you to questions/approvals, explains errors, or stays silent for trivial output. A 30KB context budget per session prevents flooding.

### Working Notifications

After sending a command, a confirmation tone plays immediately. If Claude takes more than 10 seconds, Gemini tells you "Claude is still working on it" (up to 3 times). Configurable via `VOICE_WORKING_NOTIFICATIONS` env var.

### Mic Button States

| State | Color | Animation | Meaning |
|---|---|---|---|
| idle | dark | none | not connected |
| connecting | grey | slow pulse | getting token / connecting |
| active | green | medium pulse | listening for speech |
| speaking | purple | fast pulse | Gemini is talking |

### Technical Details

- **Audio**: Mic captured at 48kHz, downsampled to 16kHz PCM16 via AudioWorklet, sent as base64. Gemini responds with 24kHz PCM16.
- **Echo prevention**: Mic muted while Gemini speaks, unmuted on `turnComplete`. 10-second safety timer force-unmutes if `turnComplete` never arrives.
- **Session renewal**: Gemini sessions have a 10-minute limit. Auto-renews at 9 minutes (brief interruption).
- **Debug panel**: Long-press the status bar to toggle. Shows all Gemini messages, mic status, connection events.

---

## Setup

### Prerequisites

| Requirement | Purpose | Install |
|---|---|---|
| **macOS** | node-pty needs native compilation | — |
| **Node.js v18+** | Server runtime | [nodejs.org](https://nodejs.org) or `brew install node` |
| **Claude Code** | The AI tool being controlled | `npm install -g @anthropic-ai/claude-code` |
| **Tailscale** | Secure network between Mac and phone | [tailscale.com](https://tailscale.com/download) (free) |
| **Gemini API key** | Voice mode (optional) | [aistudio.google.com](https://aistudio.google.com) (free) |

### Option A: macOS App (Recommended)

1. Install **[Node.js](https://nodejs.org)** (v18+) and **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** if you don't have them
2. **[Download the DMG](https://github.com/MadsLangkilde/remote-claude/releases/latest)** and drag Remote Claude to Applications
3. **Launch** it — if macOS shows "cannot be opened", right-click the app and select **Open**, then click **Open** in the dialog. An icon appears in your menu bar. On first launch, the app extracts server files to `~/projects/remote-claude/` and installs npm dependencies
4. Click **Setup Guide...** to configure Tailscale, HTTPS certificate, and Gemini API key
5. **Start Server** from the menu bar
6. **Show QR Code** and scan it with your phone

**Build from source:**

```bash
swiftc -O -o macos-app/RemoteClaude macos-app/RemoteClaude.swift -framework Cocoa
cp macos-app/RemoteClaude ~/Applications/Remote\ Claude.app/Contents/MacOS/RemoteClaude
```

### Option B: Command Line

```bash
git clone https://github.com/MadsLangkilde/remote-claude.git
cd remote-claude
npm install
chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper

# Set up Tailscale, then:
remote-claude cert        # Generate HTTPS certificate
remote-claude set-key     # Set Gemini API key (optional)
remote-claude start       # Start the server
```

Open `https://YOUR_TAILSCALE_IP:3456` on your phone. Accept the certificate warning, then add to your home screen for a fullscreen PWA experience.

### HTTPS Certificate

Mobile browsers require HTTPS for microphone access. Generate a self-signed certificate tied to your Tailscale IP:

```bash
remote-claude cert
```

Or manually:

```bash
mkdir -p certs
openssl req -x509 -newkey rsa:2048 \
  -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes \
  -subj "/CN=remote-claude" \
  -addext "subjectAltName=IP:YOUR_TAILSCALE_IP"
```

Regenerate when your Tailscale IP changes.

---

## Usage

### On Your Phone

1. Open the URL shown in the menu bar app or `remote-claude url`
2. Pick a project, choose a session mode, use the terminal
3. **Voice**: Tap mic, wait for green, speak naturally, listen for Gemini's summary

**Tips:**
- Long-press the status bar for the debug log
- Tap "Disconnect" to return to project browser (PTY stays alive)
- Terminal supports flick scrolling with momentum

### From the Command Line

```
Usage: remote-claude [command]

Server:   start, start-bg, stop, restart, status, logs [n]
Config:   url, cert, set-path, set-key
Other:    version, help
```

---

## Project Structure

```
remote-claude/
├── server.js                       # HTTPS + WebSocket server, PTY management
├── public/
│   ├── index.html                  # Frontend (project browser + terminal)
│   ├── app.js                      # Client logic (xterm, voice, touch, reconnect)
│   ├── audio-worklet-processor.js  # AudioWorklet: mic capture, downsample to 16kHz
│   ├── manifest.json               # PWA manifest
│   ├── sw.js                       # Service worker (network-only)
│   └── icon-*.png                  # PWA icons
├── macos-app/
│   ├── RemoteClaude.swift          # Menu bar app source (single file)
│   ├── RemoteClaude.icns           # App icon
│   └── dmg-background.png          # DMG installer background
├── remote-claude                   # CLI management script (bash)
├── build-dmg.sh                    # Build DMG installer
├── certs/                          # Self-signed HTTPS cert (generated, not in repo)
└── package.json                    # Dependencies: express, ws, node-pty
```

---

## Building the DMG Installer

```bash
./build-dmg.sh
```

Compiles the Swift binary, generates the app icon, assembles a `.app` bundle, and packages everything into a compressed DMG with a drag-to-install layout. Output: `RemoteClaude-1.0.dmg`.

---

## Troubleshooting

**Server won't start — "EADDRINUSE"**
Port 3456 is already in use. `remote-claude stop` to kill the other instance.

**PTY spawn fails — "posix_spawnp failed"**
Run `chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper`

**"Nested session" error**
The `CLAUDECODE` env var is leaking. The server handles this automatically, but if running manually, `unset CLAUDECODE` first.

**Phone can't connect**
Check both devices are on Tailscale (`tailscale status`), the server is running (`remote-claude status`), and the URL uses your Tailscale IP.

**Mic not working**
HTTPS is required. Check the cert is valid and browser mic permissions are granted.

**Voice not responding**
Check the API key is set (`remote-claude status`). Open the debug log (long-press status bar) for details. Sessions auto-renew every 9 minutes — brief interruptions are normal.

---

Made by Mads Vejen Langkilde
