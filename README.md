# Remote Claude

Control [Claude Code](https://docs.anthropic.com/en/docs/claude-code) from your phone. A mobile-first web terminal with persistent sessions, voice control via Gemini, and a macOS menu bar companion app.

```
  +──────────────+          Tailscale          +──────────────+
  |    Phone     | <──── private network ────> |     Mac      |
  |              |                             |              |
  |  Terminal UI |     wss (HTTPS + WS)        |  server.js   |
  |  Voice ctrl  | <────────────────────────>  |  node-pty    |
  |  Project nav |        port 3456            |  Claude Code |
  +──────────────+                             +──────────────+
        |                                            |
        |  mic audio (PCM16 @ 16kHz)                 |
        +──────────────────────────────────>  Google Gemini
        <──────────────────────────────────   Live API
          voice responses (PCM16 @ 24kHz)     (function calling)
```

## Why

Claude Code is a terminal tool. It's great at your desk, but once you kick off a task and walk away, you have no way to check on it, approve tool use, or give follow-up instructions from your phone.

Remote Claude fixes that. Start a session on your Mac, then monitor and control it from anywhere — with full terminal access and hands-free voice control.

## Features

```
  +-----------------------------------------------------+
  |  Project Browser              Terminal + Voice       |
  |                                                      |
  |  +------------------+   +--------------------------+ |
  |  | > projects/      |   | $ claude                 | |
  |  |   > web-app/     |   |                          | |
  |  |     my-site      |-->| I'll create the test...  | |
  |  |   > backend/     |   |                          | |
  |  |     api-svc      |   | Allow edit? (y/n)        | |
  |  |   cli-tool       |   |                          | |
  |  +------------------+   +--------------------------+ |
  |                          | [Enter] [Mode] [Mic]    | |
  |  Resume / New / YOLO     | [Up] [Left] [Down] [Rt] | |
  |                          +--------------------------+ |
  +------------------------------------------------------+
```

- **Project browser** — auto-detects projects under `~/projects/` by looking for `.git`, `package.json`, `Cargo.toml`, `go.mod`, `Makefile`, etc.
- **Session modes** — Resume (continue last conversation), New (fresh start), or YOLO (skip all permission prompts)
- **Persistent sessions** — PTY stays alive for 30 minutes when your phone goes to sleep. Reconnect and pick up exactly where you left off with full output replay
- **Voice control** — speak naturally and Gemini translates your intent into terminal actions
- **PWA** — add to your home screen for a fullscreen, app-like experience
- **macOS menu bar app** — start/stop server, show QR code, set API keys, view logs, onboarding guide
- **CLI management** — full command-line control for starting, stopping, and configuring the server

---

## How It Works

### Architecture

Remote Claude has three layers: a Node.js server on your Mac, a web frontend on your phone, and (optionally) Google Gemini for voice.

```
  +================================================================+
  |                         YOUR MAC                                |
  |                                                                 |
  |  server.js (Express + WebSocket + node-pty)                     |
  |  +-----------------------------------------------------------+ |
  |  |                                                            | |
  |  |  HTTPS server (:3456)         PTY Session Manager          | |
  |  |  +-----------------+         +-------------------------+   | |
  |  |  | GET /            |         | ptySessions Map         |   | |
  |  |  |   static files  |         |                         |   | |
  |  |  | GET /api/projects|         |  project-a --> pty_1    |   | |
  |  |  | GET /api/status  |         |  project-b --> pty_2    |   | |
  |  |  | GET /api/config  |         |                         |   | |
  |  |  | POST /api/       |         | Each PTY:               |   | |
  |  |  |   gemini-token   |         |  - node-pty process     |   | |
  |  |  +-----------------+         |  - 100KB replay buffer  |   | |
  |  |                               |  - listener set (WSs)   |   | |
  |  |  WebSocket handler            |  - 30-min grace timer   |   | |
  |  |  +-----------------+         +-------------------------+   | |
  |  |  | start   --> attach or spawn PTY                      |   | |
  |  |  | input   --> pty.write(data)                          |   | |
  |  |  | resize  --> pty.resize(cols, rows)                   |   | |
  |  |  | ping    --> pong                                     |   | |
  |  |  +-----------------+                                    |   | |
  |  +-----------------------------------------------------------+ |
  +================================================================+
              |                          ^
        WebSocket (wss)           WebSocket (wss)
              |                          |
              v                          |
  +================================================================+
  |                     PHONE (browser)                             |
  |                                                                 |
  |  index.html + app.js                                            |
  |  +-----------------------------------------------------------+ |
  |  |  Project Browser  -->  Session Options  -->  Terminal       | |
  |  |  (folder tree)        (resume/new/yolo)     (xterm.js)     | |
  |  |                                                            | |
  |  |  Control bar: [Enter] [Mode] [Mic] + arrow keys           | |
  |  |  Touch scroll: custom momentum physics                     | |
  |  |  Auto-reconnect on wake from background                    | |
  |  +-----------------------------------------------------------+ |
  |  |  Gemini Voice (when mic active)                            | |
  |  |  +------------------------------------------------------+ | |
  |  |  | AudioWorklet --> PCM16 @ 16kHz --> Gemini WS          | | |
  |  |  | Gemini audio <-- PCM16 @ 24kHz <-- Gemini WS          | | |
  |  |  | Function calls --> sendInput() --> PTY                 | | |
  |  |  | Terminal output --> clientContent --> Gemini            | | |
  |  |  +------------------------------------------------------+ | |
  |  +-----------------------------------------------------------+ |
  +================================================================+
```

### The Server

The server (`server.js`) is an Express app that:

1. **Serves the frontend** — static files from `public/`
2. **Manages WebSocket connections** — each phone connects via WebSocket to interact with a PTY
3. **Maintains persistent PTY sessions** — Claude Code runs in `node-pty` pseudoterminals that survive WebSocket disconnects

When a phone connects and sends a `start` message:
- If a PTY already exists for that project, the server **reattaches** — sends the replay buffer (last 100KB of output) and adds the WebSocket as a listener
- If no PTY exists, the server **spawns** Claude Code via `node-pty` in the project directory

The PTY stays alive even when all WebSocket connections drop (phone goes to sleep). A 30-minute grace timer starts. If the phone reconnects within that window, it reattaches seamlessly. If the PTY exits while the phone was away, the server auto-resumes with `claude --continue`.

### The Frontend

The frontend (`public/index.html` + `public/app.js`) has three screens:

1. **Project Browser** — fetches the project tree from `/api/projects`, displays folders and projects. Projects are detected by marker files (`.git`, `package.json`, `Cargo.toml`, `go.mod`, `Makefile`, etc.)

2. **Session Options** — choose Resume, New, or YOLO mode before launching

3. **Terminal** — full xterm.js terminal with:
   - Control buttons (Enter, Mode/Shift+Tab, arrow keys)
   - Custom touch scroll with momentum physics (xterm.js native scroll feels jerky on mobile)
   - Auto-reconnect on `visibilitychange` (phone waking from background)
   - Gemini voice button

---

## Voice Control — Gemini as the Bridge

Voice control is the core innovation. Instead of dumb speech-to-text, Google Gemini acts as an **intelligent intermediary** between your voice and Claude Code.

### What Gemini Does

Gemini receives your speech, understands your intent, and translates it into precise terminal actions using function calls. It also monitors Claude's output and gives you spoken summaries — so you don't have to stare at the screen.

```
  +---------------------------------------------------------------+
  |                                                                |
  |  YOU SAY:              GEMINI UNDERSTANDS:     ACTION:         |
  |  ─────────────         ─────────────────       ──────────      |
  |  "approve that"        intent: approve     --> y + Enter       |
  |  "no don't do that"    intent: reject      --> n + Enter       |
  |  "option 2"            intent: select #2   --> 2 + Enter       |
  |  "switch mode"         intent: toggle      --> Shift+Tab       |
  |  "escape"              intent: special key --> Escape           |
  |                                                                |
  |  "uh can you like      intent: find code   --> send_text(      |
  |   look through the     (cleans up speech)      "Find where     |
  |   code and find                                 the database   |
  |   where the database                            connection is  |
  |   thing is set up"                              configured")   |
  |                                                                |
  |  "make a test for      intent: write test  --> send_text(      |
  |   the login function,  (distills intent)       "Write a test   |
  |   you know the one                              for the login  |
  |   in auth.js"                                   function in    |
  |                                                 auth.js")      |
  |                                                                |
  +---------------------------------------------------------------+
```

Gemini is not a second AI assistant — it's a **voice bridge**. It never tries to answer coding questions itself. Every instruction goes to Claude via function calls.

### The Full Voice Flow

Here's exactly what happens when you tap the mic and speak:

```
  Step 1: Connect
  ───────────────
  Tap mic button
       |
       v
  Fetch API key from server (POST /api/gemini-token)
       |
       v
  Open WebSocket to Gemini Live API
  wss://generativelanguage.googleapis.com/ws/...
       |
       v
  Send setup message (model, tools, system prompt, voice config)
       |
       v
  Gemini responds: { setupComplete: true }
       |
       v
  Start mic capture via AudioWorklet
  Send current terminal screen as context
  Button turns green (active)


  Step 2: Speak
  ─────────────
  You speak into phone mic
       |
       v
  AudioWorklet captures at native sample rate (48kHz)
  Downsamples to 16kHz, converts float32 --> Int16 PCM
       |
       v
  Main thread encodes PCM16 --> base64
       |
       v
  Sends to Gemini via WebSocket:
  { realtimeInput: { mediaChunks: [{ mimeType: "audio/pcm;rate=16000", data: "..." }] } }
       |
       v
  Gemini processes speech (automatic end-of-speech detection)


  Step 3: Gemini Acts
  ───────────────────
  Gemini decides what to do:
       |
       +-- Command? --> toolCall: send_text({ text: "..." })
       |                    |
       |                    v
       |                Server writes text + Enter to PTY
       |                Confirmation tone plays immediately
       |                Gemini says "Sent" (brief acknowledgment)
       |
       +-- Approval? --> toolCall: approve()
       |                    |
       |                    v
       |                Server writes "y" + Enter to PTY
       |
       +-- Rejection? --> toolCall: reject()
       |                    |
       |                    v
       |                Server writes "n" + Enter to PTY
       |
       +-- Option? --> toolCall: select_option({ number: N })
       |                    |
       |                    v
       |                Server writes "N" + Enter to PTY
       |
       +-- Special key? --> toolCall: send_special({ key: "..." })
                               |
                               v
                           Server writes escape sequence to PTY


  Step 4: Claude Responds
  ───────────────────────
  Claude produces terminal output
       |
       v
  Server forwards output to phone (WebSocket: { type: "output" })
  Phone renders in xterm.js
       |
       v
  Output is also stripped of ANSI codes, debounced (2.5s),
  and forwarded to Gemini as clientContent:
  "[TERMINAL OUTPUT - result of your last action] ..."
       |
       v
  Gemini reads the output and decides:
       |
       +-- Substantial result --> Speaks summary:
       |   "Claude created three test files and they all pass."
       |
       +-- Question/prompt --> Speaks what Claude is asking:
       |   "Claude wants to know if it can modify server.js"
       |
       +-- Error --> Explains the problem:
       |   "There's a type error on line 42 — missing import"
       |
       +-- Trivial/progress --> Stays silent
```

### Function Calling Tools

Gemini has five tools available via function calling:

```
  +------------------+----------------------------------------+---------------+
  | Tool             | When Gemini calls it                   | Sends to PTY  |
  +------------------+----------------------------------------+---------------+
  | send_text(text)  | User gives instruction to type         | text + Enter  |
  | send_special(key)| User says "escape", "up", "tab", etc.  | escape seq    |
  | approve()        | User says "yes", "approve", "go ahead" | y + Enter     |
  | reject()         | User says "no", "reject", "cancel"     | n + Enter     |
  | select_option(n) | User says "option 1", "pick two"       | n + Enter     |
  +------------------+----------------------------------------+---------------+
```

### Speech Interpretation

Gemini doesn't just transcribe — it interprets. The system prompt instructs it to:

1. **Clean up speech** — remove filler words ("uh", "like", "you know"), false starts, and repetitions
2. **Distill intent** — turn rambling explanations into concise Claude prompts
3. **Never pass raw commands** — unless the user specifically asks to run a shell command
4. **Wait for completion** — don't send partial instructions; wait for the user to finish their thought

### Terminal Output Summarization

When Claude produces output, it's forwarded to Gemini for voice summarization:

```
  Claude output (raw terminal, 500+ lines)
       |
       v
  stripAnsi()          Remove ANSI escape codes
       |
       v
  debounce 2.5s        Wait for output to settle
       |
       v
  categorize:
    - Action result?   (within 30s of a function call)
    - Prompt/question? (ends with ?, contains y/n, approve, etc.)
    - Substantial?     (more than 50 chars)
       |
       v
  truncate if > 3KB    Keep head + tail with [...truncated...]
       |
       v
  Forward to Gemini as clientContent with instruction prefix:
    "[TERMINAL OUTPUT - result of your last action. Summarize.]"
       |
       v
  Gemini speaks a summary to the user
```

A context budget (30KB per session) prevents flooding Gemini with too much terminal output.

### Working Notifications

When Claude takes a long time to respond:

```
  Function call executed (e.g., send_text)
       |
       +-- immediate: confirmation tone (880Hz, 100ms)
       +-- immediate: Gemini says "Sent" (1-2 word acknowledgment)
       |
       v
  10 seconds pass, no output forwarded
       |
       v
  Gemini tells user: "Claude is still working on it"
       |
       v
  15 more seconds...
       |
       v
  Gemini: "Still processing..."  (max 3 notifications)
       |
       v
  Output finally arrives --> forwarded to Gemini --> summary spoken
```

This is configurable via the `VOICE_WORKING_NOTIFICATIONS` environment variable (default: `true`).

### Audio Pipeline

```
  Phone mic (native sample rate, typically 48kHz)
       |
       v
  AudioWorklet (audio-worklet-processor.js)
       | downsample to 16kHz
       | float32 --> Int16 PCM
       v
  Main thread
       | Int16 --> base64 string
       v
  WebSocket to Gemini
       | { realtimeInput: { mediaChunks: [...] } }
       v
  ~~~ Gemini processes speech ~~~
       |
       v
  Response: serverContent.modelTurn.parts[].inlineData
       | audio/pcm @ 24kHz, base64 encoded
       v
  Main thread
       | base64 --> Int16 --> float32
       v
  AudioContext (24kHz) --> phone speaker
```

### Echo Prevention

The mic is muted while Gemini is speaking to prevent feedback loops:

```
  You speak --> Gemini starts responding (modelTurn)
                     |
                micMuted = true   (stop sending audio chunks)
                     |
                Gemini speaks / executes function calls
                     |
                { turnComplete: true }
                     |
                micMuted = false  (resume mic)
```

A 10-second safety timer force-unmutes the mic if `turnComplete` is never received.

### Session Renewal

Gemini sessions have a 10-minute limit. The client auto-renews at 9 minutes:

```
  0:00  Session starts
  ...
  9:00  Auto-disconnect + reconnect
        New WebSocket, new setup, mic restarts
        Terminal context re-sent
  ...
  18:00 Auto-renew again
  ...
```

### Mic Button States

```
  State        Color     Animation       Meaning
  ─────        ─────     ─────────       ───────
  idle         dark      none            not connected
  connecting   grey      slow pulse      getting token / connecting
  active       green     medium pulse    listening for speech
  speaking     purple    fast pulse      Gemini is talking
```

---

## Session Persistence

Your Claude sessions survive phone disconnects. This is critical for mobile — phones constantly drop WebSocket connections when the screen locks or you switch apps.

```
  Phone active         Phone sleeps           Phone wakes up
  ────────────         ────────────           ──────────────
  Browser <--WS--> Server              Browser reconnects
                       |                       |
                    WS drops                send { start }
                       |                       |
                    PTY stays alive          Server finds PTY
                    (30-min grace)              |
                       |                    Replay 100KB buffer
                    Claude keeps               |
                    working...              You see current state
                                            including any prompts
                                            Claude is waiting on

  If PTY exited while you were away:
  ──────────────────────────────────
  Server auto-resumes with --continue
  "[Session ended while away — auto-resuming...]"
```

The replay buffer holds the last 100KB of terminal output. When you reconnect, this is sent immediately so you see exactly what Claude has been doing while you were away.

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

1. **Download** the DMG from Releases and drag Remote Claude to Applications
2. **Launch** it — a mic icon appears in your menu bar
3. **Click it** and select **Setup Guide...** — this walks you through everything:
   - Checks Node.js and Claude Code are installed
   - Explains Tailscale setup
   - Generates the HTTPS certificate
   - Sets up Gemini API key
4. **Start Server** from the menu bar
5. **Show QR Code** and scan it with your phone

The menu bar app provides:

```
  +-------------------------------+
  | Status: Running               |
  |   2 active, 5 total, up 1h   |
  |------------------------------ |
  | Stop Server              Cmd+S|
  |------------------------------ |
  |   https://100.x.y.z:3456     |
  | Show QR Code             Cmd+R|
  | Copy Phone URL           Cmd+C|
  | Open in Browser          Cmd+O|
  |------------------------------ |
  | Gemini API Key: Set      Cmd+K|
  | Setup Guide...                |
  | Show Logs                Cmd+L|
  |------------------------------ |
  | About Remote Claude           |
  | Quit                     Cmd+Q|
  +-------------------------------+
```

**Build from source** (if not using the DMG):

```bash
swiftc -O -o macos-app/RemoteClaude macos-app/RemoteClaude.swift -framework Cocoa
cp macos-app/RemoteClaude ~/Applications/Remote\ Claude.app/Contents/MacOS/RemoteClaude
```

Or build a full DMG installer:

```bash
./build-dmg.sh
```

### Option B: Command Line

```bash
# Clone
git clone https://github.com/madsvejen/remote-claude.git
cd remote-claude

# Install dependencies
npm install

# Fix node-pty spawn helper permissions (required)
chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper

# Set up Tailscale (install from tailscale.com, then)
tailscale up

# Generate HTTPS certificate (required for phone mic access)
remote-claude cert

# Set Gemini API key (optional, for voice mode)
remote-claude set-key

# Start the server
remote-claude start
```

Then open `https://YOUR_TAILSCALE_IP:3456` on your phone. Accept the self-signed certificate warning (this is normal and safe on your private network).

For the best experience, add it to your home screen: Share > Add to Home Screen. It runs as a fullscreen PWA.

### HTTPS Certificate

Mobile browsers require HTTPS for microphone access. The server uses a self-signed certificate tied to your Tailscale IP.

**Via CLI:**

```bash
remote-claude cert
```

**Manually:**

```bash
mkdir -p certs
openssl req -x509 -newkey rsa:2048 \
  -keyout certs/key.pem -out certs/cert.pem \
  -days 365 -nodes \
  -subj "/CN=remote-claude" \
  -addext "subjectAltName=IP:YOUR_TAILSCALE_IP"
```

**Via macOS app:** The Setup Guide has a one-click "Generate Certificate" button.

When your Tailscale IP changes, regenerate the certificate.

### Gemini Voice Setup

Get a free API key from [Google AI Studio](https://aistudio.google.com):

1. Sign in and click "Get API Key"
2. Create a key

**Via CLI:**

```bash
remote-claude set-key YOUR_KEY
```

**Via macOS app:** Click "Gemini API Key" in the menu bar.

**Via file:**

```bash
echo "YOUR_KEY" > ~/.gemini-api-key
```

Restart the server after setting the key.

---

## Usage

### On Your Phone

1. Open the URL shown in the menu bar app or `remote-claude url`
2. Accept the certificate warning (first time only)
3. Pick a project from the browser
4. Choose Resume, New, or YOLO mode
5. Use the terminal — type on your phone's keyboard, use the control buttons

**Voice mode:**
1. Tap the mic button (bottom control bar)
2. Wait for it to turn green
3. Speak naturally — "approve that", "write a test for the login function", "no, cancel"
4. Gemini translates your speech and sends it to Claude
5. Listen for Gemini's spoken summary of what Claude did
6. Tap mic again to disconnect

**Tips:**
- Long-press the status bar to open the debug log (shows all Gemini messages)
- Tap "Disconnect" to return to the project browser (your PTY session stays alive)
- The terminal supports flick scrolling with momentum

### From the Command Line

```
Usage: remote-claude [command]

Server:
  start       Start server in foreground (see all output)
  start-bg    Start server in background
  stop        Stop the server
  restart     Restart the server (foreground)
  status      Show server status and stats
  logs [n]    Tail the log file (default: last 50 lines, live)

Config:
  url         Show the phone access URL
  cert        Generate HTTPS certificate for Tailscale IP
  set-path    Set the projects directory
  set-key     Set the Gemini API key (for voice mode)

Other:
  version     Show version
  help        Show this help
```

**Examples:**

```bash
# Start in background
remote-claude start-bg

# Check status
remote-claude status
#   RUNNING  PID: 12345
#   Uptime:      2h 30m 15s
#   Active:      1 connection(s)
#   Phone URL:   https://100.x.y.z:3456

# See last 100 log lines (live tail)
remote-claude logs 100

# Show the phone access URL
remote-claude url
#   https://100.x.y.z:3456

# Generate HTTPS cert for current Tailscale IP
remote-claude cert
#   Certificate generated for 100.x.y.z

# Set projects directory
remote-claude set-path ~/my-code

# Set Gemini API key
remote-claude set-key AIza...
```

To make `remote-claude` available anywhere:

```bash
ln -sf "$(pwd)/remote-claude" ~/.local/bin/remote-claude
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
│   ├── icon-192.png                # PWA icon
│   └── icon-512.png                # PWA icon + source for .icns
├── macos-app/
│   ├── RemoteClaude.swift          # Menu bar app source (single file)
│   ├── RemoteClaude.icns           # App icon
│   └── dmg-background.png          # DMG installer background
├── remote-claude                   # CLI management script (bash)
├── build-dmg.sh                    # Build DMG installer
├── certs/                          # Self-signed HTTPS cert (generated, not in repo)
├── package.json                    # Dependencies: express, ws, node-pty
├── CLAUDE.md                       # AI assistant context
└── .gitignore
```

---

## Building the DMG Installer

The `build-dmg.sh` script creates a macOS DMG installer from source. It compiles the Swift binary, generates the app icon, assembles a full `.app` bundle, and packages everything into a compressed DMG with a drag-to-install layout.

```bash
./build-dmg.sh
```

This will:
1. Compile `RemoteClaude.swift` into an optimized binary
2. Generate `.icns` icon from `public/icon-512.png`
3. Assemble `Remote Claude.app` with Info.plist, icon, and binary
4. Create a DMG containing the app, an Applications symlink, and a Getting Started guide
5. Set the Finder window layout (app on left, Applications on right)
6. Compress the DMG and install a copy to `~/Applications`

Output: `RemoteClaude-1.0.dmg` in the project root.

---

## Troubleshooting

**Server won't start — "EADDRINUSE"**
Port 3456 is already in use. Stop the other instance: `remote-claude stop`

**PTY spawn fails — "posix_spawnp failed"**
The node-pty spawn helper needs execute permission:
```bash
chmod +x node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper
```

**"Nested session" error when Claude starts**
The `CLAUDECODE` environment variable leaks into the child process. The server already handles this, but if you're running manually, make sure to `unset CLAUDECODE` first.

**Phone can't connect**
- Ensure both devices are on the same Tailscale network (`tailscale status`)
- Check the server is running (`remote-claude status`)
- Verify the URL uses your Tailscale IP, not localhost

**Certificate warning on phone**
This is expected for self-signed certificates. Tap "Advanced" > "Proceed" (Chrome) or "Show Details" > "visit this website" (Safari). You only need to do this once.

**Mic not working on phone**
- HTTPS is required — the server must be running with a valid cert
- Check browser permissions (Settings > Site Settings > Microphone)
- Restart voice mode (tap mic off, then on)

**Voice mode says "Ready!" repeatedly**
Gemini got stuck. Tap the mic button off and on to reconnect.

**No voice response from Gemini**
- Check that the API key is set (`remote-claude status`)
- Check the debug log (long-press status bar on phone)
- The Gemini session auto-renews every 9 minutes — brief interruptions are normal

**Gemini voice is delayed**
This is inherent to the round-trip: speech > Gemini > function call > Claude > output > Gemini > audio. A confirmation tone plays immediately when your command is sent so you know it was received.

---

---

Made by Mads Vejen Langkilde
