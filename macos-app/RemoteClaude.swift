import Cocoa
import CoreImage

// ─── Config ─────────────────────────────────────────────────────
let HOME = FileManager.default.homeDirectoryForCurrentUser.path
let PROJECT_DIR = "\(HOME)/projects/remote-claude"
let PID_FILE = "\(PROJECT_DIR)/remote-claude.pid"
let LOG_FILE = "\(PROJECT_DIR)/remote-claude.log"
let SERVER_JS = "\(PROJECT_DIR)/server.js"
let NODE_PATH = "/usr/local/bin/node"
let PORT = 3456
let GEMINI_KEY_FILE = "\(HOME)/.gemini-api-key"
let PROJECTS_CONFIG_FILE = "\(HOME)/.remote-claude-config"
let PROJECTS_ROOT_DEFAULT = "\(HOME)/projects"
let ONBOARDING_FILE = "\(PROJECT_DIR)/.onboarding-complete"

// ─── App Delegate ───────────────────────────────────────────────
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var toggleMenuItem: NSMenuItem!
    var statusTimer: Timer?
    var serverProcess: Process?

    // Windows
    var dashWindow: NSWindow?
    var logWindow: NSWindow?
    var qrWindow: NSWindow?
    var onboardingWindow: NSWindow?

    // Dashboard dynamic labels
    var dashStatusDot: NSTextField?
    var dashStatusText: NSTextField?
    var dashStatsText: NSTextField?
    var dashToggleBtn: NSButton?
    var dashURLLabel: NSTextField?
    var dashConnSection: NSView?
    var dashGeminiVal: NSTextField?
    var dashProjectsVal: NSTextField?
    var dashCertVal: NSTextField?

    // Log viewer
    var logTextView: NSTextView!
    var logFileHandle: FileHandle?
    var logMonitorSource: DispatchSourceFileSystemObject?

    // Onboarding
    var onboardingPage = 0
    var onboardingContentArea: NSView!
    var onboardingBackBtn: NSButton!
    var onboardingNextBtn: NSButton!
    var onboardingStepLabel: NSTextField!
    let onboardingPageCount = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Enable Cmd+C/V/X/A in text fields (menu bar apps lack a main menu)
        let mainMenu = NSMenu()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(); editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(running: false)
        ensureServerFiles()
        clearQuarantine()
        buildMenu()
        startStatusPolling()

        if !FileManager.default.fileExists(atPath: ONBOARDING_FILE) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func updateMenuBarIcon(running: Bool) {
        guard let button = statusItem.button else { return }
        guard let img = loadMenuBarIcon() else {
            button.title = running ? "RC" : "rc"; return
        }
        let size = NSSize(width: 18, height: 18)
        let result = NSImage(size: size)
        result.lockFocus()
        // White circle background
        let circle = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        NSColor.white.setFill()
        circle.fill()
        // Draw logo on top, inset slightly
        let inset: CGFloat = 2
        img.draw(in: NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2),
                 from: .zero, operation: .sourceOver, fraction: running ? 1.0 : 0.4)
        result.unlockFocus()
        result.isTemplate = false
        button.image = result
    }

    func loadMenuBarIcon() -> NSImage? {
        // Try app bundle Resources
        let execPath = ProcessInfo.processInfo.arguments[0]
        let contentsDir = ((execPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let icnsPath = (contentsDir as NSString).appendingPathComponent("Resources/RemoteClaude.icns")
        if let img = NSImage(contentsOfFile: icnsPath) { return img }
        // Fallback: project logo
        let logoPath = "\(PROJECT_DIR)/macos-app/logo.png"
        if let img = NSImage(contentsOfFile: logoPath) { return img }
        return nil
    }

    // ─── Auto-Setup ─────────────────────────────────────────────
    func ensureServerFiles() {
        let serverJs = "\(PROJECT_DIR)/server.js"
        if FileManager.default.fileExists(atPath: serverJs) {
            ensureDependencies()
            return
        }
        guard let bundledServer = bundledServerPath() else { return }
        try? FileManager.default.createDirectory(atPath: PROJECT_DIR, withIntermediateDirectories: true)
        if let items = try? FileManager.default.contentsOfDirectory(atPath: bundledServer) {
            for item in items {
                let src = "\(bundledServer)/\(item)"
                let dst = "\(PROJECT_DIR)/\(item)"
                if !FileManager.default.fileExists(atPath: dst) {
                    try? FileManager.default.copyItem(atPath: src, toPath: dst)
                }
            }
        }
        ensureDependencies()
    }

    func bundledServerPath() -> String? {
        let execPath = ProcessInfo.processInfo.arguments[0]
        let macosDir = (execPath as NSString).deletingLastPathComponent
        let contentsDir = (macosDir as NSString).deletingLastPathComponent
        let serverDir = (contentsDir as NSString).appendingPathComponent("Resources").appending("/server")
        return FileManager.default.fileExists(atPath: serverDir) ? serverDir : nil
    }

    func ensureDependencies() {
        let ptyPath = "\(PROJECT_DIR)/node_modules/node-pty"
        if FileManager.default.fileExists(atPath: ptyPath) { return }
        let npmPaths = ["/usr/local/bin/npm", "/opt/homebrew/bin/npm"]
        var npmPath: String?
        for p in npmPaths { if FileManager.default.fileExists(atPath: p) { npmPath = p; break } }
        guard let npm = npmPath else { return }
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: npm)
            task.arguments = ["install"]
            task.currentDirectoryURL = URL(fileURLWithPath: PROJECT_DIR)
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
            let helper = "\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
            if FileManager.default.fileExists(atPath: helper) { chmod(helper, 0o755) }
            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-cr", "\(PROJECT_DIR)/node_modules"]
            xattr.standardOutput = FileHandle.nullDevice
            xattr.standardError = FileHandle.nullDevice
            try? xattr.run()
            xattr.waitUntilExit()
        }
    }

    func clearQuarantine() {
        let nm = "\(PROJECT_DIR)/node_modules"
        if FileManager.default.fileExists(atPath: nm) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            task.arguments = ["-cr", nm]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    // ─── Menu (minimal — just quick actions) ────────────────────
    func buildMenu() {
        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "s")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let dashItem = NSMenuItem(title: "Open Dashboard", action: #selector(showDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // ─── Status Polling ─────────────────────────────────────────
    func startStatusPolling() {
        checkStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkStatus()
        }
    }

    func isServerRunning() -> Bool {
        if let pidStr = try? String(contentsOfFile: PID_FILE, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if kill(pid, 0) == 0 { return true }
        }
        return isPortInUse(PORT)
    }

    func isPortInUse(_ port: Int) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit(); return !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty }
        catch { return false }
    }

    func getTailscaleIP() -> String? {
        for path in ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"] {
            if FileManager.default.fileExists(atPath: path) {
                let task = Process(); task.executableURL = URL(fileURLWithPath: path); task.arguments = ["ip", "-4"]
                let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
                do { try task.run(); task.waitUntilExit()
                    if let ip = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty { return ip }
                } catch {}
            }
        }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/env"); task.arguments = ["tailscale", "ip", "-4"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit()
            let ip = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (ip?.isEmpty == false) ? ip : nil
        } catch { return nil }
    }

    func getServerURL() -> String {
        return "https://\(getTailscaleIP() ?? "localhost"):\(PORT)"
    }

    func fetchStats() -> (active: Int, total: Int, msgs: Int, uptime: String)? {
        guard let url = URL(string: "https://localhost:\(PORT)/api/status") else { return nil }
        let session = URLSession(configuration: .default, delegate: InsecureDelegate(), delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Int, Int, String)?
        let task = session.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let a = json["activeConnections"] as? Int, let t = json["totalConnections"] as? Int,
                  let m = json["totalMessages"] as? Int, let u = json["uptime"] as? Int else { return }
            result = (a, t, m, "\(u/3600)h \((u%3600)/60)m \(u%60)s")
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return result
    }

    func checkStatus() {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let running = self.isServerRunning()
            let stats = running ? self.fetchStats() : nil
            let serverURL = running ? self.getServerURL() : nil
            DispatchQueue.main.async {
                self.updateMenuBarIcon(running: running)
                self.toggleMenuItem.title = running ? "Stop Server" : "Start Server"
                self.updateDashboardStatus(running: running, stats: stats, url: serverURL)
            }
        }
    }

    // ─── Server Control ─────────────────────────────────────────
    @objc func toggleServer() {
        if isServerRunning() { stopServer() } else { startServer() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.checkStatus() }
    }

    func startServer() {
        let kill = Process(); kill.executableURL = URL(fileURLWithPath: "/bin/bash")
        kill.arguments = ["-c", "lsof -ti tcp:\(PORT) | xargs kill -9 2>/dev/null; true"]
        try? kill.run(); kill.waitUntilExit()
        try? "".write(toFile: LOG_FILE, atomically: true, encoding: .utf8)

        let task = Process(); task.executableURL = URL(fileURLWithPath: NODE_PATH)
        task.arguments = [SERVER_JS]; task.currentDirectoryURL = URL(fileURLWithPath: PROJECT_DIR)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE"); env["PROJECTS_ROOT"] = getProjectsRoot()
        task.environment = env
        let outPipe = Pipe(); task.standardOutput = outPipe; task.standardError = outPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let fh = FileHandle(forWritingAtPath: LOG_FILE) {
                fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
            }
        }
        do { try task.run(); serverProcess = task; appendToLog("Server starting (PID \(task.processIdentifier))...\n") }
        catch { appendToLog("Failed to start: \(error.localizedDescription)\n") }
    }

    func stopServer() {
        if let pidStr = try? String(contentsOfFile: PID_FILE, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM); usleep(500_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "lsof -ti tcp:\(PORT) | xargs kill -9 2>/dev/null; true"]
        try? task.run(); task.waitUntilExit()
        serverProcess = nil; appendToLog("Server stopped.\n")
    }

    // ─── Dashboard Window ───────────────────────────────────────
    @objc func showDashboard() {
        if let w = dashWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let W: CGFloat = 520, H: CGFloat = 560
        let P: CGFloat = 25 // padding
        let CW: CGFloat = W - P * 2 // content width

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Remote Claude"
        window.center()
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        var y: CGFloat = H - 40

        // ── Title ──
        let title = NSTextField(labelWithString: "Remote Claude")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.frame = NSRect(x: P, y: y, width: CW, height: 28)
        root.addSubview(title)
        y -= 22

        let subtitle = NSTextField(labelWithString: "Access Claude Code from your phone")
        subtitle.font = NSFont.systemFont(ofSize: 13); subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: P, y: y, width: CW, height: 18)
        root.addSubview(subtitle)
        y -= 28

        // ── SERVER section ──
        addSectionHeader("SERVER", at: y, in: root); y -= 30

        dashStatusDot = NSTextField(labelWithString: "\u{25CF}")
        dashStatusDot!.font = NSFont.systemFont(ofSize: 14)
        dashStatusDot!.frame = NSRect(x: P, y: y, width: 18, height: 20)
        root.addSubview(dashStatusDot!)

        dashStatusText = NSTextField(labelWithString: "Checking...")
        dashStatusText!.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        dashStatusText!.frame = NSRect(x: P + 20, y: y, width: 200, height: 20)
        root.addSubview(dashStatusText!)

        dashToggleBtn = NSButton(frame: NSRect(x: W - P - 130, y: y - 4, width: 130, height: 28))
        dashToggleBtn!.title = "Start Server"; dashToggleBtn!.bezelStyle = .rounded
        dashToggleBtn!.target = self; dashToggleBtn!.action = #selector(toggleServer)
        root.addSubview(dashToggleBtn!)
        y -= 24

        dashStatsText = NSTextField(labelWithString: "")
        dashStatsText!.font = NSFont.systemFont(ofSize: 11); dashStatsText!.textColor = .tertiaryLabelColor
        dashStatsText!.frame = NSRect(x: P + 20, y: y, width: 300, height: 16)
        root.addSubview(dashStatsText!)
        y -= 26

        addSeparator(at: y, in: root); y -= 20

        // ── CONNECTION section ──
        dashConnSection = NSView(frame: NSRect(x: 0, y: y - 80, width: W, height: 100))
        var cy: CGFloat = 78

        addSectionHeader("CONNECTION", at: cy, in: dashConnSection!); cy -= 28

        dashURLLabel = NSTextField(labelWithString: "https://...")
        dashURLLabel!.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        dashURLLabel!.isSelectable = true
        dashURLLabel!.frame = NSRect(x: P, y: cy, width: CW, height: 20)
        dashConnSection!.addSubview(dashURLLabel!)
        cy -= 32

        let qrBtn = NSButton(frame: NSRect(x: P, y: cy, width: 120, height: 28))
        qrBtn.title = "Show QR Code"; qrBtn.bezelStyle = .rounded
        qrBtn.target = self; qrBtn.action = #selector(showQRCode)
        dashConnSection!.addSubview(qrBtn)

        let copyBtn = NSButton(frame: NSRect(x: P + 128, y: cy, width: 100, height: 28))
        copyBtn.title = "Copy URL"; copyBtn.bezelStyle = .rounded
        copyBtn.target = self; copyBtn.action = #selector(copyURL)
        dashConnSection!.addSubview(copyBtn)

        let browserBtn = NSButton(frame: NSRect(x: P + 236, y: cy, width: 130, height: 28))
        browserBtn.title = "Open in Browser"; browserBtn.bezelStyle = .rounded
        browserBtn.target = self; browserBtn.action = #selector(openInBrowser)
        dashConnSection!.addSubview(browserBtn)

        root.addSubview(dashConnSection!)
        y -= 105

        addSeparator(at: y, in: root); y -= 20

        // ── SETTINGS section ──
        addSectionHeader("SETTINGS", at: y, in: root); y -= 28

        // Projects Folder
        let projLabel = NSTextField(labelWithString: "Projects Folder")
        projLabel.font = NSFont.systemFont(ofSize: 13)
        projLabel.frame = NSRect(x: P, y: y, width: 120, height: 20)
        root.addSubview(projLabel)

        dashProjectsVal = NSTextField(labelWithString: "")
        dashProjectsVal!.font = NSFont.systemFont(ofSize: 12); dashProjectsVal!.textColor = .secondaryLabelColor
        dashProjectsVal!.lineBreakMode = .byTruncatingMiddle
        dashProjectsVal!.frame = NSRect(x: P + 125, y: y, width: 230, height: 20)
        root.addSubview(dashProjectsVal!)

        let projBtn = NSButton(frame: NSRect(x: W - P - 90, y: y - 2, width: 90, height: 22))
        projBtn.title = "Change..."; projBtn.bezelStyle = .rounded; projBtn.controlSize = .small
        projBtn.font = NSFont.systemFont(ofSize: 11)
        projBtn.target = self; projBtn.action = #selector(chooseProjectsFolder)
        root.addSubview(projBtn)
        y -= 30

        // Gemini API Key
        let gemLabel = NSTextField(labelWithString: "Gemini API Key")
        gemLabel.font = NSFont.systemFont(ofSize: 13)
        gemLabel.frame = NSRect(x: P, y: y, width: 120, height: 20)
        root.addSubview(gemLabel)

        dashGeminiVal = NSTextField(labelWithString: "")
        dashGeminiVal!.font = NSFont.systemFont(ofSize: 12); dashGeminiVal!.textColor = .secondaryLabelColor
        dashGeminiVal!.frame = NSRect(x: P + 125, y: y, width: 230, height: 20)
        root.addSubview(dashGeminiVal!)

        let gemBtn = NSButton(frame: NSRect(x: W - P - 90, y: y - 2, width: 90, height: 22))
        gemBtn.title = "Change..."; gemBtn.bezelStyle = .rounded; gemBtn.controlSize = .small
        gemBtn.font = NSFont.systemFont(ofSize: 11)
        gemBtn.target = self; gemBtn.action = #selector(setGeminiKey)
        root.addSubview(gemBtn)
        y -= 30

        // HTTPS Certificate
        let certLabel = NSTextField(labelWithString: "HTTPS Certificate")
        certLabel.font = NSFont.systemFont(ofSize: 13)
        certLabel.frame = NSRect(x: P, y: y, width: 130, height: 20)
        root.addSubview(certLabel)

        dashCertVal = NSTextField(labelWithString: "")
        dashCertVal!.font = NSFont.systemFont(ofSize: 12); dashCertVal!.textColor = .secondaryLabelColor
        dashCertVal!.frame = NSRect(x: P + 135, y: y, width: 220, height: 20)
        root.addSubview(dashCertVal!)

        let certBtn = NSButton(frame: NSRect(x: W - P - 90, y: y - 2, width: 90, height: 22))
        certBtn.title = "Regenerate"; certBtn.bezelStyle = .rounded; certBtn.controlSize = .small
        certBtn.font = NSFont.systemFont(ofSize: 11)
        certBtn.target = self; certBtn.action = #selector(obGenerateCert)
        root.addSubview(certBtn)
        y -= 36

        addSeparator(at: y, in: root); y -= 24

        // ── TOOLS row ──
        let logsBtn = NSButton(frame: NSRect(x: P, y: y, width: 120, height: 28))
        logsBtn.title = "Show Logs"; logsBtn.bezelStyle = .rounded
        logsBtn.target = self; logsBtn.action = #selector(showLogs)
        root.addSubview(logsBtn)

        let setupBtn = NSButton(frame: NSRect(x: P + 128, y: y, width: 130, height: 28))
        setupBtn.title = "Setup Guide..."; setupBtn.bezelStyle = .rounded
        setupBtn.target = self; setupBtn.action = #selector(showOnboarding)
        root.addSubview(setupBtn)
        y -= 10

        // ── Footer ──
        let footer = NSTextField(labelWithString: "Made by Mads Vejen Langkilde \u{00B7} v1.0")
        footer.font = NSFont.systemFont(ofSize: 10); footer.textColor = .tertiaryLabelColor
        footer.frame = NSRect(x: P, y: 12, width: CW, height: 14)
        root.addSubview(footer)

        window.contentView = root
        dashWindow = window

        // Populate current values
        refreshDashboardSettings()
        checkStatus()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func addSectionHeader(_ text: String, at y: CGFloat, in view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 25, y: y, width: 470, height: 15)
        view.addSubview(label)
    }

    func addSeparator(at y: CGFloat, in view: NSView) {
        let sep = NSBox(frame: NSRect(x: 25, y: y, width: 470, height: 1))
        sep.boxType = .separator
        view.addSubview(sep)
    }

    func updateDashboardStatus(running: Bool, stats: (active: Int, total: Int, msgs: Int, uptime: String)?, url: String?) {
        guard dashWindow != nil else { return }
        dashStatusDot?.textColor = running ? .systemGreen : .systemRed
        dashStatusText?.stringValue = running ? "Running" : "Stopped"
        dashToggleBtn?.title = running ? "Stop Server" : "Start Server"

        if let s = stats {
            dashStatsText?.stringValue = "\(s.active) active, \(s.total) total, \(s.msgs) msgs, up \(s.uptime)"
        } else {
            dashStatsText?.stringValue = ""
        }

        if running, let u = url {
            dashURLLabel?.stringValue = u
            dashConnSection?.isHidden = false
        } else {
            dashConnSection?.isHidden = true
        }
    }

    func refreshDashboardSettings() {
        let projPath = (getProjectsRoot() as NSString).abbreviatingWithTildeInPath
        dashProjectsVal?.stringValue = projPath
        dashGeminiVal?.stringValue = isGeminiKeyConfigured() ? "\u{2713} Configured" : "\u{2717} Not set"
        dashGeminiVal?.textColor = isGeminiKeyConfigured() ? .systemGreen : .systemRed
        if checkCertsExist() {
            if let ip = getCertIP() { dashCertVal?.stringValue = "\u{2713} Ready (\(ip))" }
            else { dashCertVal?.stringValue = "\u{2713} Ready" }
            dashCertVal?.textColor = .systemGreen
        } else {
            dashCertVal?.stringValue = "\u{2717} Missing"
            dashCertVal?.textColor = .systemRed
        }
    }

    // ─── Log Window ─────────────────────────────────────────────
    @objc func showLogs() {
        if let w = logWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); scrollLogToBottom(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Remote Claude — Logs"; window.center(); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 450, height: 300)
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)

        let barH: CGFloat = 38
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: barH)); bar.autoresizingMask = [.width]

        let saveBtn = NSButton(frame: NSRect(x: 10, y: 5, width: 110, height: 28))
        saveBtn.title = "Save as TXT..."; saveBtn.bezelStyle = .rounded; saveBtn.target = self; saveBtn.action = #selector(saveLogs)
        bar.addSubview(saveBtn)
        let clearBtn = NSButton(frame: NSRect(x: 126, y: 5, width: 70, height: 28))
        clearBtn.title = "Clear"; clearBtn.bezelStyle = .rounded; clearBtn.target = self; clearBtn.action = #selector(clearLogs)
        bar.addSubview(clearBtn)
        let lineCount = NSTextField(labelWithString: "")
        lineCount.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        lineCount.textColor = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        lineCount.alignment = .right; lineCount.frame = NSRect(x: 450, y: 9, width: 240, height: 16)
        lineCount.autoresizingMask = [.minXMargin]; lineCount.tag = 200
        bar.addSubview(lineCount)
        window.contentView?.addSubview(bar)

        let sep = NSBox(frame: NSRect(x: 0, y: barH, width: 700, height: 1)); sep.boxType = .separator; sep.autoresizingMask = [.width]
        window.contentView?.addSubview(sep)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: barH + 1, width: 700, height: 500 - barH - 1))
        scrollView.autoresizingMask = [.width, .height]; scrollView.hasVerticalScroller = true
        logTextView = NSTextView(frame: scrollView.bounds); logTextView.autoresizingMask = [.width]
        logTextView.isEditable = false
        logTextView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        logTextView.textColor = NSColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1.0)
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 10, height: 10)
        scrollView.documentView = logTextView; window.contentView?.addSubview(scrollView)

        logWindow = window; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        loadExistingLogs(); startLogMonitoring()
    }

    @objc func saveLogs() {
        let panel = NSSavePanel(); panel.title = "Save Logs"
        panel.nameFieldStringValue = "remote-claude-\(logTimestamp()).txt"
        panel.allowedContentTypes = [.plainText]
        guard let w = logWindow else { return }
        panel.beginSheetModal(for: w) { response in
            guard response == .OK, let url = panel.url else { return }
            try? ((try? String(contentsOfFile: LOG_FILE, encoding: .utf8)) ?? "").write(to: url, atomically: true, encoding: .utf8)
        }
    }
    func logTimestamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f.string(from: Date()) }
    @objc func clearLogs() {
        try? "".write(toFile: LOG_FILE, atomically: true, encoding: .utf8)
        logTextView?.textStorage?.setAttributedString(NSAttributedString(string: "")); updateLogLineCount()
    }
    func loadExistingLogs() { if let c = try? String(contentsOfFile: LOG_FILE, encoding: .utf8) { appendColoredLog(c) } }
    func startLogMonitoring() {
        stopLogMonitoring()
        guard FileManager.default.fileExists(atPath: LOG_FILE), let fh = FileHandle(forReadingAtPath: LOG_FILE) else { return }
        fh.seekToEndOfFile(); logFileHandle = fh
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fh.fileDescriptor, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            let data = fh.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty { self?.appendColoredLog(str) }
        }
        source.setCancelHandler { fh.closeFile() }; source.resume(); logMonitorSource = source
    }
    func stopLogMonitoring() { logMonitorSource?.cancel(); logMonitorSource = nil; logFileHandle = nil }
    func appendColoredLog(_ text: String) {
        guard let tv = logTextView else { return }; let storage = tv.textStorage!
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty { continue }
            var color = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)
            if line.contains("ERROR") || line.contains("FATAL") { color = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0) }
            else if line.contains("WARN") { color = NSColor(red: 0.9, green: 0.8, blue: 0.3, alpha: 1.0) }
            else if line.contains("CONN") { color = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0) }
            else if line.contains("DISC") { color = NSColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1.0) }
            else if line.contains("START") { color = NSColor(red: 0.4, green: 0.8, blue: 0.95, alpha: 1.0) }
            else if line.contains("INFO") { color = NSColor(red: 0.78, green: 0.63, blue: 1.0, alpha: 1.0) }
            storage.append(NSAttributedString(string: line + "\n", attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
        }
        scrollLogToBottom(); updateLogLineCount()
    }
    func scrollLogToBottom() { logTextView?.scrollToEndOfDocument(nil) }
    func updateLogLineCount() {
        guard let tv = logTextView, let label = logWindow?.contentView?.viewWithTag(200) as? NSTextField else { return }
        let lines = tv.string.components(separatedBy: "\n").count - 1; let bytes = tv.string.utf8.count
        if bytes > 1048576 { label.stringValue = "\(lines) lines  \u{00B7}  \(String(format: "%.1f", Double(bytes)/1048576.0)) MB" }
        else if bytes > 1024 { label.stringValue = "\(lines) lines  \u{00B7}  \(bytes/1024) KB" }
        else { label.stringValue = "\(lines) lines" }
    }
    func appendToLog(_ text: String) {
        if let fh = FileHandle(forWritingAtPath: LOG_FILE) { fh.seekToEndOfFile(); fh.write(text.data(using: .utf8)!); fh.closeFile() }
    }

    // ─── QR Code ────────────────────────────────────────────────
    func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8), let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let ctx = CIContext(); guard let cg = ctx.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let img = NSImage(size: NSSize(width: 260, height: 260)); img.lockFocus()
        NSGraphicsContext.current?.cgContext.interpolationQuality = .none
        NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: 260, height: 260))
        img.unlockFocus(); return img
    }

    @objc func showQRCode() {
        if let w = qrWindow { w.close(); qrWindow = nil }
        let url = getServerURL()
        guard let qrImage = generateQRCode(from: url) else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remote Claude — Connect"; window.center(); window.isReleasedWhenClosed = false; window.backgroundColor = .white
        let content = NSView(frame: window.contentView!.bounds)
        let urlLabel = NSTextField(labelWithString: url)
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold); urlLabel.alignment = .center; urlLabel.isSelectable = true
        urlLabel.frame = NSRect(x: 10, y: 358, width: 300, height: 28); content.addSubview(urlLabel)
        let hint = NSTextField(labelWithString: "Scan with your phone camera")
        hint.font = NSFont.systemFont(ofSize: 13); hint.textColor = .secondaryLabelColor; hint.alignment = .center
        hint.frame = NSRect(x: 10, y: 332, width: 300, height: 20); content.addSubview(hint)
        let iv = NSImageView(frame: NSRect(x: 30, y: 55, width: 260, height: 260)); iv.image = qrImage; content.addSubview(iv)
        let cpBtn = NSButton(frame: NSRect(x: 90, y: 12, width: 140, height: 32))
        cpBtn.title = "Copy URL"; cpBtn.bezelStyle = .rounded; cpBtn.target = self; cpBtn.action = #selector(copyURLFromQR(_:))
        content.addSubview(cpBtn)
        window.contentView = content; qrWindow = window
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func copyURLFromQR(_ sender: NSButton) {
        copyURL(); let o = sender.title; sender.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.title = o }
    }

    // ─── Settings helpers ───────────────────────────────────────
    func isGeminiKeyConfigured() -> Bool {
        guard let c = try? String(contentsOfFile: GEMINI_KEY_FILE, encoding: .utf8) else { return false }
        return !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc func setGeminiKey() {
        let alert = NSAlert(); alert.messageText = "Gemini API Key"
        alert.informativeText = "Enter your key from aistudio.google.com\nRestart the server after changing the key."
        alert.alertStyle = .informational; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "AIza..."; input.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        if let e = try? String(contentsOfFile: GEMINI_KEY_FILE, encoding: .utf8) { input.stringValue = e.trimmingCharacters(in: .whitespacesAndNewlines) }
        alert.accessoryView = input; NSApp.activate(ignoringOtherApps: true); alert.window.makeFirstResponder(input)
        if alert.runModal() == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { try? FileManager.default.removeItem(atPath: GEMINI_KEY_FILE) }
            else { try? key.write(toFile: GEMINI_KEY_FILE, atomically: true, encoding: .utf8) }
            refreshDashboardSettings()
        }
    }

    func getProjectsRoot() -> String {
        if let c = try? String(contentsOfFile: PROJECTS_CONFIG_FILE, encoding: .utf8) {
            let p = c.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty && FileManager.default.fileExists(atPath: p) { return p }
        }
        return PROJECTS_ROOT_DEFAULT
    }

    @objc func chooseProjectsFolder() {
        let panel = NSOpenPanel(); panel.title = "Choose Projects Folder"
        panel.message = "Select the folder that contains your projects.\nRestart the server after changing this."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: getProjectsRoot())
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? url.path.write(toFile: PROJECTS_CONFIG_FILE, atomically: true, encoding: .utf8)
            refreshDashboardSettings()
        }
    }

    func checkCertsExist() -> Bool {
        FileManager.default.fileExists(atPath: "\(PROJECT_DIR)/certs/cert.pem") &&
        FileManager.default.fileExists(atPath: "\(PROJECT_DIR)/certs/key.pem")
    }
    func getCertIP() -> String? {
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = ["x509", "-in", "\(PROJECT_DIR)/certs/cert.pem", "-noout", "-ext", "subjectAltName"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let range = output.range(of: "IP Address:") {
                let ip = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: CharacterSet.newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
                return ip.isEmpty ? nil : ip
            }
        } catch {}; return nil
    }

    // ─── Actions ────────────────────────────────────────────────
    @objc func copyURL() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(getServerURL(), forType: .string)
    }
    @objc func openInBrowser() { NSWorkspace.shared.open(URL(string: "https://localhost:\(PORT)")!) }
    @objc func quitApp() { NSApp.terminate(nil) }

    // ─── Onboarding ─────────────────────────────────────────────
    func obLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                 color: NSColor = .labelColor, width: CGFloat = 490) -> NSTextField {
        let tf = NSTextField(wrappingLabelWithString: text)
        tf.font = NSFont.systemFont(ofSize: size, weight: weight); tf.textColor = color
        tf.isEditable = false; tf.isBezeled = false; tf.drawsBackground = false
        tf.preferredMaxLayoutWidth = width; tf.frame.size.width = width
        if let cell = tf.cell { tf.frame.size.height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height }
        return tf
    }
    func obStatusRow(_ ok: Bool, _ name: String, _ detail: String = "") -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 20))
        let icon = NSTextField(labelWithString: ok ? "\u{2713}" : "\u{2717}")
        icon.font = NSFont.systemFont(ofSize: 13, weight: .bold); icon.textColor = ok ? .systemGreen : .systemRed
        icon.frame = NSRect(x: 0, y: 0, width: 20, height: 20); row.addSubview(icon)
        let lbl = NSTextField(labelWithString: name); lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.frame = NSRect(x: 24, y: 0, width: 240, height: 20); row.addSubview(lbl)
        if !detail.isEmpty {
            let d = NSTextField(labelWithString: detail); d.font = NSFont.systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor; d.alignment = .right
            d.frame = NSRect(x: 270, y: 0, width: 220, height: 20); row.addSubview(d)
        }
        return row
    }
    func obButton(_ title: String, action: Selector, tag: Int = 0) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        btn.title = title; btn.bezelStyle = .rounded; btn.target = self; btn.action = action; btn.tag = tag; return btn
    }
    func obSpacer(_ h: CGFloat = 6) -> NSView { NSView(frame: NSRect(x: 0, y: 0, width: 490, height: h)) }
    func obLayout(title: String, elements: [NSView]) -> NSView {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 435))
        let t = NSTextField(labelWithString: title); t.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        t.isBezeled = false; t.isEditable = false; t.drawsBackground = false
        t.frame = NSRect(x: 35, y: 390, width: 490, height: 35); page.addSubview(t)
        var y: CGFloat = 378
        for el in elements { let h = max(el.frame.height, 18); y -= h
            el.frame.origin = NSPoint(x: 35, y: y); if el.frame.width < 1 { el.frame.size.width = 490 }
            page.addSubview(el); y -= 6 }
        return page
    }
    func checkNodeInstalled() -> Bool { FileManager.default.fileExists(atPath: NODE_PATH) }
    func checkClaudeInstalled() -> Bool { FileManager.default.fileExists(atPath: "\(HOME)/.local/bin/claude") }
    func checkDepsInstalled() -> Bool { FileManager.default.fileExists(atPath: "\(PROJECT_DIR)/node_modules/node-pty") }
    func checkSpawnHelper() -> Bool { FileManager.default.isExecutableFile(atPath: "\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper") }

    @objc func showOnboarding() {
        if let w = onboardingWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remote Claude — Setup"; window.center(); window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentView!.bounds)
        onboardingContentArea = NSView(frame: NSRect(x: 0, y: 55, width: 560, height: 445)); root.addSubview(onboardingContentArea)
        let sep = NSBox(frame: NSRect(x: 0, y: 54, width: 560, height: 1)); sep.boxType = .separator; root.addSubview(sep)
        onboardingBackBtn = NSButton(frame: NSRect(x: 20, y: 12, width: 100, height: 32))
        onboardingBackBtn.title = "Back"; onboardingBackBtn.bezelStyle = .rounded; onboardingBackBtn.target = self; onboardingBackBtn.action = #selector(onboardingBack); root.addSubview(onboardingBackBtn)
        onboardingStepLabel = NSTextField(labelWithString: ""); onboardingStepLabel.font = NSFont.systemFont(ofSize: 12)
        onboardingStepLabel.textColor = .secondaryLabelColor; onboardingStepLabel.alignment = .center
        onboardingStepLabel.frame = NSRect(x: 180, y: 18, width: 200, height: 18); root.addSubview(onboardingStepLabel)
        onboardingNextBtn = NSButton(frame: NSRect(x: 440, y: 12, width: 100, height: 32))
        onboardingNextBtn.title = "Continue"; onboardingNextBtn.bezelStyle = .rounded; onboardingNextBtn.keyEquivalent = "\r"
        onboardingNextBtn.target = self; onboardingNextBtn.action = #selector(onboardingNext); root.addSubview(onboardingNextBtn)
        window.contentView = root; onboardingWindow = window; onboardingPage = 0; renderOnboardingPage()
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func renderOnboardingPage() {
        for sub in onboardingContentArea.subviews { sub.removeFromSuperview() }
        let page: NSView
        switch onboardingPage { case 0: page = pageWelcome(); case 1: page = pageRequirements(); case 2: page = pageNetwork()
        case 3: page = pageCertificate(); case 4: page = pageVoice(); case 5: page = pageReady(); default: page = NSView() }
        onboardingContentArea.addSubview(page)
        onboardingBackBtn.isHidden = (onboardingPage == 0)
        onboardingStepLabel.stringValue = "Step \(onboardingPage + 1) of \(onboardingPageCount)"
        if onboardingPage == onboardingPageCount - 1 {
            onboardingNextBtn.title = "Start Server"; onboardingNextBtn.action = #selector(finishOnboarding)
        } else { onboardingNextBtn.title = "Continue"; onboardingNextBtn.action = #selector(onboardingNext) }
    }
    @objc func onboardingBack() { if onboardingPage > 0 { onboardingPage -= 1; renderOnboardingPage() } }
    @objc func onboardingNext() { if onboardingPage < onboardingPageCount - 1 { onboardingPage += 1; renderOnboardingPage() } }
    @objc func finishOnboarding() {
        try? "done".write(toFile: ONBOARDING_FILE, atomically: true, encoding: .utf8)
        onboardingWindow?.close(); onboardingWindow = nil
        if !isServerRunning() { startServer() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.checkStatus(); self?.showQRCode() }
    }
    func pageWelcome() -> NSView {
        obLayout(title: "Welcome to Remote Claude", elements: [obSpacer(4),
            obLabel("Remote Claude lets you use Claude Code from your phone, anywhere, anytime.", size: 14), obSpacer(8),
            obLabel("Talk to Claude with your voice, approve file changes on the go, and manage all your projects from a mobile-friendly terminal.", size: 13, color: .secondaryLabelColor), obSpacer(16),
            obLabel("What you'll set up:", size: 13, weight: .semibold), obSpacer(2),
            obLabel("  1.  Node.js and Claude Code (the core tools)\n  2.  A private network so your phone can reach your Mac\n  3.  An HTTPS certificate for secure microphone access\n  4.  A Gemini API key for hands-free voice mode", size: 13), obSpacer(16),
            obLabel("It only takes a few minutes. You can re-open this guide\nanytime from the Dashboard.", size: 12, color: .tertiaryLabelColor)])
    }
    func pageRequirements() -> NSView {
        let n = checkNodeInstalled(), c = checkClaudeInstalled(), d = checkDepsInstalled(), s = checkSpawnHelper()
        var items: [NSView] = [obSpacer(4), obLabel("Remote Claude needs these tools installed on your Mac:", size: 13), obSpacer(8),
            obStatusRow(n, "Node.js", n ? NODE_PATH : "Not found"), obStatusRow(c, "Claude Code CLI", c ? "~/.local/bin/claude" : "Not found"),
            obStatusRow(d, "npm dependencies", d ? "Installed" : "Not installed")]
        if d { items.append(obStatusRow(s, "node-pty spawn helper", s ? "Executable" : "Not executable")) }
        items.append(obSpacer(12))
        if !n { items.append(obLabel("Install Node.js (v18+) from nodejs.org or via Homebrew:\n  brew install node", size: 12, color: .secondaryLabelColor)); items.append(obSpacer(4)) }
        if !c { items.append(obLabel("Install Claude Code:\n  npm install -g @anthropic-ai/claude-code", size: 12, color: .secondaryLabelColor)); items.append(obSpacer(4)) }
        if !d && n { items.append(obButton("Install Dependencies", action: #selector(obInstallDeps), tag: 101)) }
        else if d && !s { items.append(obButton("Fix Permissions", action: #selector(obFixSpawnHelper))) }
        return obLayout(title: "Requirements", elements: items)
    }
    @objc func obInstallDeps() {
        if let btn = onboardingContentArea.viewWithTag(101) as? NSButton { btn.isEnabled = false; btn.title = "Installing..." }
        DispatchQueue.global().async { [weak self] in
            let npmPaths = ["/usr/local/bin/npm", "/opt/homebrew/bin/npm"]; var np: String?
            for p in npmPaths { if FileManager.default.fileExists(atPath: p) { np = p; break } }
            guard let npm = np else { return }
            let t = Process(); t.executableURL = URL(fileURLWithPath: npm); t.arguments = ["install"]
            t.currentDirectoryURL = URL(fileURLWithPath: PROJECT_DIR); t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
            try? t.run(); t.waitUntilExit()
            let h = "\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
            if FileManager.default.fileExists(atPath: h) { chmod(h, 0o755) }
            DispatchQueue.main.async { self?.renderOnboardingPage() }
        }
    }
    @objc func obFixSpawnHelper() { chmod("\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper", 0o755); renderOnboardingPage() }
    func pageNetwork() -> NSView {
        let ip = getTailscaleIP(); let has = ip != nil
        var items: [NSView] = [obSpacer(4),
            obLabel("To use Claude from your phone, both devices need to be on the same private network. A regular home Wi-Fi works if both are connected, but won't work when you're away from home.", size: 13), obSpacer(10),
            obLabel("We recommend Tailscale", size: 14, weight: .semibold), obSpacer(2),
            obLabel("Tailscale is a free, zero-config VPN that creates a secure encrypted tunnel between your devices, no matter where they are.", size: 13, color: .secondaryLabelColor), obSpacer(8),
            obLabel("  1.  Install Tailscale on your Mac  (tailscale.com/download)\n  2.  Install Tailscale on your phone  (App Store / Play Store)\n  3.  Sign in with the same account on both\n  4.  Done, they can now reach each other securely", size: 13), obSpacer(12),
            obStatusRow(has, "Tailscale", has ? "Connected: \(ip!)" : "Not detected")]
        if !has { items.append(obSpacer(4)); items.append(obButton("Open tailscale.com", action: #selector(obOpenTailscale))); items.append(obSpacer(8))
            items.append(obLabel("You can also use any other VPN or network setup.", size: 12, color: .tertiaryLabelColor)) }
        return obLayout(title: "Secure Remote Access", elements: items)
    }
    @objc func obOpenTailscale() { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download")!) }
    func pageCertificate() -> NSView {
        let has = checkCertsExist(); let cip = has ? getCertIP() : nil; let tip = getTailscaleIP()
        var items: [NSView] = [obSpacer(4),
            obLabel("Mobile browsers require HTTPS for microphone access, which powers the voice assistant. A self-signed certificate is generated for your network IP address.", size: 13), obSpacer(4),
            obLabel("When you first visit the URL on your phone, the browser will show a certificate warning. This is normal, tap \"Advanced\" and proceed.", size: 12, color: .secondaryLabelColor), obSpacer(12)]
        if has {
            if let c = cip { items.append(obStatusRow(true, "Certificate found", "IP: \(c)"))
                if let t = tip, c != t { items.append(obStatusRow(false, "IP mismatch", "Tailscale is \(t)")); items.append(obSpacer(4))
                    items.append(obLabel("Regenerate to match your current Tailscale address.", size: 12, color: .systemOrange)); items.append(obSpacer(4))
                    items.append(obButton("Regenerate Certificate", action: #selector(obGenerateCert))) }
            } else { items.append(obStatusRow(true, "Certificate found", "")) }
        } else { items.append(obStatusRow(false, "No certificate", "")); items.append(obSpacer(4))
            if tip != nil { items.append(obButton("Generate Certificate", action: #selector(obGenerateCert))) }
            else { items.append(obLabel("Set up Tailscale first so the certificate can be issued for your IP.", size: 12, color: .systemOrange)) } }
        return obLayout(title: "HTTPS Certificate", elements: items)
    }
    @objc func obGenerateCert() {
        guard let ip = getTailscaleIP() else {
            let a = NSAlert(); a.messageText = "Tailscale Not Detected"; a.informativeText = "Connect to Tailscale first."; a.runModal(); return }
        let dir = "\(PROJECT_DIR)/certs"; try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        t.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-keyout", "\(dir)/key.pem", "-out", "\(dir)/cert.pem",
                        "-days", "365", "-nodes", "-subj", "/CN=remote-claude", "-addext", "subjectAltName=IP:\(ip)"]
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        do { try t.run(); t.waitUntilExit(); if t.terminationStatus == 0 { renderOnboardingPage(); refreshDashboardSettings() } } catch {}
    }
    func pageVoice() -> NSView {
        let has = isGeminiKeyConfigured()
        return obLayout(title: "Voice Mode (Optional)", elements: [obSpacer(4),
            obLabel("Voice mode lets you talk to Claude hands-free. Google Gemini acts as an intelligent voice bridge, it translates your speech into terminal commands and reads Claude's responses back to you.", size: 13), obSpacer(8),
            obLabel("To enable voice mode, you need a free Gemini API key:", size: 13), obSpacer(2),
            obLabel("  1.  Visit aistudio.google.com\n  2.  Click \"Get API Key\" and create one\n  3.  Click the button below to save it", size: 13), obSpacer(12),
            obStatusRow(has, "Gemini API Key", has ? "Configured" : "Not set"), obSpacer(6),
            obButton(has ? "Change API Key..." : "Set API Key...", action: #selector(obSetGeminiKey)), obSpacer(16),
            obLabel("Voice mode is optional. You can set the key later from the Dashboard.", size: 12, color: .tertiaryLabelColor)])
    }
    @objc func obSetGeminiKey() { setGeminiKey(); renderOnboardingPage() }
    func pageReady() -> NSView {
        let n = checkNodeInstalled(), c = checkClaudeInstalled(), d = checkDepsInstalled()
        let ip = getTailscaleIP(), cert = checkCertsExist(), key = isGeminiKeyConfigured()
        var items: [NSView] = [obSpacer(4), obStatusRow(n, "Node.js", n ? "Installed" : "Missing"),
            obStatusRow(c, "Claude Code", c ? "Installed" : "Missing"), obStatusRow(d, "Dependencies", d ? "Installed" : "Missing"),
            obStatusRow(ip != nil, "Tailscale", ip ?? "Not connected"), obStatusRow(cert, "HTTPS Certificate", cert ? "Ready" : "Missing"),
            obStatusRow(key, "Gemini API Key", key ? "Configured" : "Not set (voice disabled)"), obSpacer(14)]
        if isServerRunning() { items.append(obLabel("Your server is already running! Click below to see the QR code.", size: 13)) }
        else { items.append(obLabel("Click \"Start Server\" to launch Remote Claude. A QR code will appear, scan it with your phone.", size: 13)) }
        items.append(obSpacer(12)); items.append(obLabel("You can re-open this guide from the Dashboard.", size: 12, color: .tertiaryLabelColor))
        return obLayout(title: "You're All Set!", elements: items)
    }
}

// ─── Insecure URL delegate (for self-signed cert) ───────────────
class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.performDefaultHandling, nil) }
    }
}

// ─── Main ───────────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
