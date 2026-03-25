const express = require('express');
const http = require('http');
const https = require('https');
const { WebSocketServer } = require('ws');
const pty = require('node-pty');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3456;
const HOME = os.homedir();
const PROJECTS_ROOT = process.env.PROJECTS_ROOT;
const UPLOAD_DIR = path.join(os.tmpdir(), 'remote-claude-uploads');
if (!PROJECTS_ROOT) {
  console.error('FATAL: PROJECTS_ROOT environment variable is required. Set it to the directory to scan for projects.');
  process.exit(1);
}
const LOG_FILE = path.join(__dirname, 'remote-claude.log');
const PID_FILE = path.join(__dirname, 'remote-claude.pid');

// ─── Logging ────────────────────────────────────────────────────
let activeConnections = 0;
let totalConnections = 0;
let totalMessages = 0;
const startTime = Date.now();

function log(level, msg) {
  const ts = new Date().toISOString().replace('T', ' ').replace('Z', '');
  const line = `[${ts}] ${level.padEnd(5)} ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
}

function logStats() {
  const uptime = Math.floor((Date.now() - startTime) / 1000);
  const h = Math.floor(uptime / 3600);
  const m = Math.floor((uptime % 3600) / 60);
  const s = uptime % 60;
  return `[active:${activeConnections} total:${totalConnections} msgs:${totalMessages} up:${h}h${m}m${s}s]`;
}

// Write PID file
fs.writeFileSync(PID_FILE, process.pid.toString());
process.on('exit', () => { try { fs.unlinkSync(PID_FILE); } catch {} });
process.on('SIGTERM', () => { log('INFO', 'Received SIGTERM, shutting down'); process.exit(0); });
process.on('SIGINT', () => { log('INFO', 'Received SIGINT, shutting down'); process.exit(0); });

// HTTPS certs (self-signed for Tailscale access)
const certDir = path.join(__dirname, 'certs');
const certFile = path.join(certDir, 'cert.pem');
const keyFile = path.join(certDir, 'key.pem');
const useHttps = fs.existsSync(certFile) && fs.existsSync(keyFile);

// ─── Gemini API key ────────────────────────────────────────────
const geminiKeyPath = path.join(HOME, '.gemini-api-key');
let geminiApiKey = null;
if (fs.existsSync(geminiKeyPath)) {
  geminiApiKey = fs.readFileSync(geminiKeyPath, 'utf-8').trim();
  log('INFO', 'Loaded Gemini API key from ~/.gemini-api-key');
} else if (process.env.GEMINI_API_KEY) {
  geminiApiKey = process.env.GEMINI_API_KEY;
  log('INFO', 'Loaded Gemini API key from GEMINI_API_KEY env var');
} else {
  log('WARN', 'No Gemini API key found (check ~/.gemini-api-key or GEMINI_API_KEY)');
}

// Ensure upload directory exists
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });

const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Check if a directory looks like a project
function isProject(dirPath) {
  const markers = ['.git', 'CLAUDE.md', 'package.json', 'CMakeLists.txt', 'build.gradle', 'build.gradle.kts', 'Cargo.toml', 'go.mod', 'Makefile'];
  return markers.some(m => fs.existsSync(path.join(dirPath, m)));
}

// Scan a directory and return its structure
function scanDir(dirPath) {
  const entries = [];
  let items;
  try {
    items = fs.readdirSync(dirPath);
  } catch {
    return entries;
  }

  for (const name of items) {
    if (name.startsWith('.') || name === 'node_modules') continue;
    const fullPath = path.join(dirPath, name);
    let stat;
    try {
      stat = fs.statSync(fullPath);
    } catch {
      continue;
    }
    if (!stat.isDirectory()) continue;

    if (isProject(fullPath)) {
      entries.push({ name, path: fullPath, type: 'project' });
    } else {
      const children = scanDir(fullPath);
      if (children.length > 0) {
        entries.push({ name, path: fullPath, type: 'folder', children });
      }
    }
  }

  return entries;
}

// API: scan ~/projects/ tree
app.get('/api/projects', (_req, res) => {
  const tree = scanDir(PROJECTS_ROOT);
  res.json(tree);
});

// API: server status
app.get('/api/status', (_req, res) => {
  res.json({
    uptime: Math.floor((Date.now() - startTime) / 1000),
    activeConnections,
    totalConnections,
    totalMessages,
    pid: process.pid,
    https: useHttps,
    home: HOME,
    projectsRoot: PROJECTS_ROOT,
  });
});

// API: Config (voice settings, etc.)
// VOICE_WORKING_NOTIFICATIONS env var controls "Claude is working" voice alerts (default: true)
app.get('/api/config', (_req, res) => {
  res.json({
    voiceWorkingNotifications: process.env.VOICE_WORKING_NOTIFICATIONS !== 'false',
  });
});

// API: Gemini API key (served over Tailscale only — not public)
app.post('/api/gemini-token', (_req, res) => {
  if (!geminiApiKey) {
    return res.status(500).json({ error: 'no_key', message: 'No Gemini API key configured. Add your key to ~/.gemini-api-key and restart the server.' });
  }
  res.json({ apiKey: geminiApiKey });
});

// API: File upload (images, PDFs, etc. for Claude to analyze)
app.post('/api/upload', express.raw({ type: '*/*', limit: '20mb' }), (req, res) => {
  try {
    const origName = req.headers['x-filename'] || 'upload';
    const safeName = origName.replace(/[^a-zA-Z0-9._-]/g, '_');
    const filePath = path.join(UPLOAD_DIR, `${Date.now()}-${safeName}`);
    fs.writeFileSync(filePath, req.body);
    log('INFO', `File uploaded: ${filePath} (${req.body.length} bytes)`);
    res.json({ path: filePath });
  } catch (e) {
    log('ERROR', `Upload failed: ${e.message}`);
    res.status(500).json({ error: e.message });
  }
});

const server = useHttps
  ? https.createServer({ cert: fs.readFileSync(certFile), key: fs.readFileSync(keyFile) }, app)
  : http.createServer(app);
const wss = new WebSocketServer({ server });
wss.on('error', () => {});

// ─── Persistent PTY sessions ────────────────────────────────────
// Keep PTYs alive across WebSocket reconnects (phone standby etc.)
const PTY_GRACE_MS = 30 * 60 * 1000; // 30 minutes before killing orphaned PTY
const REPLAY_BUFFER_SIZE = 100000; // chars of recent output to replay on reconnect
const ptySessions = new Map(); // projectPath → { pty, replayBuffer, killTimer, name, exited, exitCode }

function getOrCreatePty(projectDir, msg) {
  // Clean up old exited session if it existed
  const existing = ptySessions.get(projectDir);
  if (existing) ptySessions.delete(projectDir);

  // Unlock keychain if password file exists
  const keychainPwPath = path.join(HOME, '.keychain-pw');
  let env = { ...process.env };
  delete env.CLAUDECODE;
  if (fs.existsSync(keychainPwPath)) {
    const pw = fs.readFileSync(keychainPwPath, 'utf-8').trim();
    const { execSync } = require('child_process');
    try {
      execSync(`security unlock-keychain -p "${pw}" ~/Library/Keychains/login.keychain-db`, {
        stdio: 'ignore',
      });
    } catch (e) {
      log('WARN', `Failed to unlock keychain: ${e.message}`);
    }
  }

  // Spawn claude in a PTY
  const claudePath = path.join(HOME, '.local/bin/claude');
  let claudeCmd = claudePath;
  if (msg.mode === 'resume') {
    claudeCmd = `${claudePath} --continue`;
  } else if (msg.mode === 'resume-pick') {
    claudeCmd = `${claudePath} --resume`;
  } else if (msg.mode === 'yolo') {
    claudeCmd = `${claudePath} --dangerously-skip-permissions`;
  } else if (msg.mode === 'yolo-resume') {
    claudeCmd = `${claudePath} --continue --dangerously-skip-permissions`;
  }

  const ptyProcess = pty.spawn('/bin/zsh', ['-l', '-c', claudeCmd], {
    name: 'xterm-256color',
    cols: msg.cols || 120,
    rows: msg.rows || 40,
    cwd: projectDir,
    env,
  });
  log('INFO', `Claude spawned (PID ${ptyProcess.pid}) for ${msg.name}`);

  const session = {
    pty: ptyProcess,
    replayBuffer: '',
    killTimer: null,
    name: msg.name,
    exited: false,
    exitCode: null,
    listeners: new Set(), // active WebSocket listeners
  };

  // Buffer all output for replay
  ptyProcess.onData((data) => {
    session.replayBuffer += data;
    if (session.replayBuffer.length > REPLAY_BUFFER_SIZE) {
      session.replayBuffer = session.replayBuffer.slice(-REPLAY_BUFFER_SIZE);
    }
    // Forward to all connected listeners
    for (const listener of session.listeners) {
      try {
        listener.send(JSON.stringify({ type: 'output', data }));
      } catch (e) {}
    }
  });

  ptyProcess.onExit(({ exitCode }) => {
    log('INFO', `Claude exited (code ${exitCode}) for ${msg.name}`);
    session.exited = true;
    session.exitCode = exitCode;
    session.pty = null;
    for (const listener of session.listeners) {
      try {
        listener.send(JSON.stringify({ type: 'exit', code: exitCode }));
      } catch (e) {}
    }
    // Clean up after a bit
    setTimeout(() => ptySessions.delete(projectDir), 30000);
  });

  ptySessions.set(projectDir, session);
  return { session, isNew: true };
}

wss.on('connection', (ws, req) => {
  let currentSession = null;
  const clientIp = req.headers['x-forwarded-for'] || req.socket.remoteAddress;
  activeConnections++;
  totalConnections++;
  log('CONN', `Client connected from ${clientIp} ${logStats()}`);

  ws.on('message', (raw) => {
    totalMessages++;
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      if (currentSession && currentSession.pty) currentSession.pty.write(raw.toString());
      return;
    }

    if (msg.type === 'start') {
      const projectDir = msg.path;
      log('START', `Session: ${msg.name} -> ${projectDir} [mode:${msg.mode || 'new'}] ${logStats()}`);

      if (!projectDir || !fs.existsSync(projectDir)) {
        log('ERROR', `Directory not found: ${projectDir}`);
        ws.send(JSON.stringify({ type: 'error', data: `Directory not found: ${projectDir}` }));
        return;
      }

      try {
        // Check if there's a live PTY we can reattach to
        // If user explicitly chose a different mode (yolo/new), kill the old PTY first
        // 'reconnect' mode means auto-reconnect from backgrounding — always reattach
        const existing = ptySessions.get(projectDir);
        if (existing && !existing.exited && (msg.mode === 'yolo' || msg.mode === 'new' || msg.mode === 'resume-pick')) {
          log('INFO', `Killing existing PTY for ${msg.name} (user chose ${msg.mode} mode)`);
          if (existing.pty) { try { existing.pty.kill(); } catch (e) {} }
          existing.pty = null;
          existing.exited = true;
          ptySessions.delete(projectDir);
        }

        const existingReattach = ptySessions.get(projectDir);
        if (existingReattach && !existingReattach.exited) {
          // Reattach to the live PTY
          log('INFO', `Reattaching to existing PTY (PID ${existingReattach.pty.pid}) for ${msg.name}`);
          clearTimeout(existingReattach.killTimer);
          existingReattach.killTimer = null;
          currentSession = existingReattach;
          existingReattach.listeners.add(ws);

          if (existingReattach.replayBuffer.length > 0) {
            ws.send(JSON.stringify({ type: 'output', data: existingReattach.replayBuffer }));
          }
          ws.send(JSON.stringify({ type: 'started', project: msg.name, reconnected: true }));

          if (existingReattach.pty && msg.cols && msg.rows) {
            try { existingReattach.pty.resize(msg.cols, msg.rows); } catch (e) {}
          }
          return;
        }

        // No live PTY — determine how to start/resume
        let effectiveMode = msg.mode || 'new';

        // 'reconnect' means the browser reconnected after backgrounding.
        // If PTY died, auto-resume. Use original mode flags (e.g. yolo) if provided.
        if (effectiveMode === 'reconnect') {
          const deadSession = ptySessions.get(projectDir);
          if (deadSession && deadSession.exited) {
            log('INFO', `PTY exited while disconnected for ${msg.name}, auto-resuming`);
            // Combine resume with original mode flags (e.g. yolo + resume)
            effectiveMode = msg.originalMode === 'yolo' ? 'yolo-resume' : 'resume';
            ws.send(JSON.stringify({
              type: 'output',
              data: '\r\n\x1b[33m[Session ended while you were away — auto-resuming conversation...]\x1b[0m\r\n',
            }));
          } else {
            // No PTY at all (cleaned up) — resume last conversation
            log('INFO', `No PTY found for ${msg.name} on reconnect, resuming last session`);
            effectiveMode = msg.originalMode === 'yolo' ? 'yolo-resume' : 'resume';
            ws.send(JSON.stringify({
              type: 'output',
              data: '\r\n\x1b[33m[Reconnected — resuming conversation...]\x1b[0m\r\n',
            }));
          }
        } else if (effectiveMode === 'new') {
          const deadSession = ptySessions.get(projectDir);
          if (deadSession && deadSession.exited) {
            log('INFO', `PTY exited while disconnected for ${msg.name}, auto-resuming with --continue`);
            effectiveMode = 'resume';
            ws.send(JSON.stringify({
              type: 'output',
              data: '\r\n\x1b[33m[Session ended while you were away — auto-resuming conversation...]\x1b[0m\r\n',
            }));
          }
        }

        const { session } = getOrCreatePty(projectDir, { ...msg, mode: effectiveMode });
        currentSession = session;
        session.listeners.add(ws);
        ws.send(JSON.stringify({ type: 'started', project: msg.name }));

        if (session.pty && msg.cols && msg.rows) {
          try { session.pty.resize(msg.cols, msg.rows); } catch (e) {}
        }
      } catch (e) {
        log('ERROR', `Failed to spawn claude: ${e.message}`);
        ws.send(JSON.stringify({ type: 'error', data: `Failed to start Claude: ${e.message}` }));
      }
    }

    if (msg.type === 'ping') {
      // Keepalive — respond with pong so the client knows the connection is alive
      try { ws.send(JSON.stringify({ type: 'pong' })); } catch {}
      return;
    }

    if (msg.type === 'input' && currentSession && currentSession.pty) {
      currentSession.pty.write(msg.data);
    }

    if (msg.type === 'resize' && currentSession && currentSession.pty) {
      try {
        currentSession.pty.resize(msg.cols, msg.rows);
      } catch (e) {}
    }
  });

  ws.on('close', () => {
    activeConnections--;
    log('DISC', `Client disconnected from ${clientIp} ${logStats()}`);
    if (currentSession) {
      const session = currentSession;
      currentSession = null;
      session.listeners.delete(ws);
      // Start grace timer if no listeners remain
      if (session.listeners.size === 0 && !session.exited) {
        log('INFO', `No listeners for ${session.name}, PTY stays alive for ${PTY_GRACE_MS / 1000}s`);
        session.killTimer = setTimeout(() => {
          if (session.listeners.size === 0 && session.pty) {
            log('INFO', `Grace period expired, killing PTY for ${session.name}`);
            session.pty.kill();
            session.pty = null;
          }
        }, PTY_GRACE_MS);
      }
    }
  });
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    log('FATAL', `Port ${PORT} is already in use`);
  } else {
    log('FATAL', `Server error: ${err.message}`);
  }
  process.exit(1);
});

server.listen(PORT, '0.0.0.0', () => {
  const proto = useHttps ? 'https' : 'http';
  log('INFO', `Remote Claude server started on ${proto}://0.0.0.0:${PORT} (PID ${process.pid})`);
});
