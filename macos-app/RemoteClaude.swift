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
    var logWindow: NSWindow?
    var qrWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var logTextView: NSTextView!
    var statusMenuItem: NSMenuItem!
    var toggleMenuItem: NSMenuItem!
    var urlMenuItem: NSMenuItem!
    var statsMenuItem: NSMenuItem!
    var geminiKeyMenuItem: NSMenuItem!
    var projectsPathMenuItem: NSMenuItem!
    var qrMenuItem: NSMenuItem!
    var statusTimer: Timer?
    var logPipe: Pipe?
    var serverProcess: Process?
    var logFileHandle: FileHandle?
    var logMonitorSource: DispatchSourceFileSystemObject?

    // Onboarding state
    var onboardingPage = 0
    var onboardingContentArea: NSView!
    var onboardingBackBtn: NSButton!
    var onboardingNextBtn: NSButton!
    var onboardingStepLabel: NSTextField!
    let onboardingPageCount = 6

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(running: false)
        buildMenu()
        startStatusPolling()

        if !FileManager.default.fileExists(atPath: ONBOARDING_FILE) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    func updateMenuBarIcon(running: Bool) {
        if let button = statusItem.button {
            let symbol = running ? "mic.circle.fill" : "mic.circle"
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Remote Claude") {
                img.isTemplate = !running
                if running {
                    let colored = img.copy() as! NSImage
                    colored.isTemplate = false
                    button.image = colored
                } else {
                    button.image = img
                }
            } else {
                button.title = running ? "VC" : "vc"
            }
        }
    }

    // ─── Menu ───────────────────────────────────────────────────
    func buildMenu() {
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        statsMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statsMenuItem.isEnabled = false
        menu.addItem(statsMenuItem)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "Start Server", action: #selector(toggleServer), keyEquivalent: "s")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        urlMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        urlMenuItem.isEnabled = false
        urlMenuItem.isHidden = true
        menu.addItem(urlMenuItem)

        qrMenuItem = NSMenuItem(title: "Show QR Code", action: #selector(showQRCode), keyEquivalent: "r")
        qrMenuItem.target = self
        qrMenuItem.isHidden = true
        menu.addItem(qrMenuItem)

        let copyItem = NSMenuItem(title: "Copy Phone URL", action: #selector(copyURL), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let openBrowserItem = NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "o")
        openBrowserItem.target = self
        menu.addItem(openBrowserItem)

        menu.addItem(NSMenuItem.separator())

        geminiKeyMenuItem = NSMenuItem(title: "Gemini API Key: Checking...", action: #selector(setGeminiKey), keyEquivalent: "k")
        geminiKeyMenuItem.target = self
        menu.addItem(geminiKeyMenuItem)
        updateGeminiKeyStatus()

        projectsPathMenuItem = NSMenuItem(title: "Projects Folder: ...", action: #selector(chooseProjectsFolder), keyEquivalent: "p")
        projectsPathMenuItem.target = self
        menu.addItem(projectsPathMenuItem)
        updateProjectsPathStatus()

        let setupItem = NSMenuItem(title: "Setup Guide...", action: #selector(showOnboarding), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let logsItem = NSMenuItem(title: "Show Logs", action: #selector(showLogs), keyEquivalent: "l")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About Remote Claude", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

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
            if kill(pid, 0) == 0 {
                return true
            }
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
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return !data.isEmpty
        } catch {
            return false
        }
    }

    func getTailscaleIP() -> String? {
        let tailscalePaths = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        for path in tailscalePaths {
            if FileManager.default.fileExists(atPath: path) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: path)
                task.arguments = ["ip", "-4"]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = FileHandle.nullDevice
                do {
                    try task.run()
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !ip.isEmpty {
                        return ip
                    }
                } catch {}
            }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["tailscale", "ip", "-4"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (ip?.isEmpty == false) ? ip : nil
        } catch {
            return nil
        }
    }

    func getServerURL() -> String {
        let host = getTailscaleIP() ?? "localhost"
        return "https://\(host):\(PORT)"
    }

    func fetchStats() -> (active: Int, total: Int, msgs: Int, uptime: String)? {
        let urlStr = "https://localhost:\(PORT)/api/status"
        guard let url = URL(string: urlStr) else { return nil }

        let session = URLSession(configuration: .default, delegate: InsecureDelegate(), delegateQueue: nil)
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Int, Int, String)?

        let task = session.dataTask(with: url) { data, _, _ in
            defer { semaphore.signal() }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let active = json["activeConnections"] as? Int,
                  let total = json["totalConnections"] as? Int,
                  let msgs = json["totalMessages"] as? Int,
                  let uptime = json["uptime"] as? Int else { return }
            let h = uptime / 3600
            let m = (uptime % 3600) / 60
            let s = uptime % 60
            result = (active, total, msgs, "\(h)h \(m)m \(s)s")
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
                if running {
                    self.statusMenuItem.title = "Status: Running"
                    self.toggleMenuItem.title = "Stop Server"
                    if let s = stats {
                        self.statsMenuItem.title = "  \(s.active) active, \(s.total) total, \(s.msgs) msgs, up \(s.uptime)"
                        self.statsMenuItem.isHidden = false
                    }
                    if let url = serverURL {
                        self.urlMenuItem.title = "  \(url)"
                        self.urlMenuItem.isHidden = false
                    }
                    self.qrMenuItem.isHidden = false
                } else {
                    self.statusMenuItem.title = "Status: Stopped"
                    self.toggleMenuItem.title = "Start Server"
                    self.statsMenuItem.isHidden = true
                    self.urlMenuItem.isHidden = true
                    self.qrMenuItem.isHidden = true
                }
                self.updateGeminiKeyStatus()
            }
        }
    }

    // ─── Server Control ─────────────────────────────────────────
    @objc func toggleServer() {
        if isServerRunning() {
            stopServer()
        } else {
            startServer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkStatus()
        }
    }

    func startServer() {
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        killTask.arguments = ["-c", "lsof -ti tcp:\(PORT) | xargs kill -9 2>/dev/null; true"]
        try? killTask.run()
        killTask.waitUntilExit()

        try? "".write(toFile: LOG_FILE, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: NODE_PATH)
        task.arguments = [SERVER_JS]
        task.currentDirectoryURL = URL(fileURLWithPath: PROJECT_DIR)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        env["PROJECTS_ROOT"] = getProjectsRoot()
        task.environment = env

        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = outPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                if let fh = FileHandle(forWritingAtPath: LOG_FILE) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    fh.closeFile()
                }
            }
        }

        do {
            try task.run()
            serverProcess = task
            appendToLog("Server starting (PID \(task.processIdentifier))...\n")
        } catch {
            appendToLog("Failed to start: \(error.localizedDescription)\n")
        }
    }

    func stopServer() {
        if let pidStr = try? String(contentsOfFile: PID_FILE, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
            usleep(500_000)
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "lsof -ti tcp:\(PORT) | xargs kill -9 2>/dev/null; true"]
        try? task.run()
        task.waitUntilExit()

        serverProcess = nil
        appendToLog("Server stopped.\n")
    }

    // ─── Log Window ─────────────────────────────────────────────
    @objc func showLogs() {
        if let w = logWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            scrollLogToBottom()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Remote Claude — Logs"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 450, height: 300)
        window.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)

        let barHeight: CGFloat = 38

        // Bottom toolbar
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: barHeight))
        bar.autoresizingMask = [.width]

        let saveBtn = NSButton(frame: NSRect(x: 10, y: 5, width: 110, height: 28))
        saveBtn.title = "Save as TXT..."
        saveBtn.bezelStyle = .rounded
        saveBtn.target = self
        saveBtn.action = #selector(saveLogs)
        bar.addSubview(saveBtn)

        let clearBtn = NSButton(frame: NSRect(x: 126, y: 5, width: 70, height: 28))
        clearBtn.title = "Clear"
        clearBtn.bezelStyle = .rounded
        clearBtn.target = self
        clearBtn.action = #selector(clearLogs)
        bar.addSubview(clearBtn)

        let lineCount = NSTextField(labelWithString: "")
        lineCount.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        lineCount.textColor = NSColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        lineCount.alignment = .right
        lineCount.frame = NSRect(x: 450, y: 9, width: 240, height: 16)
        lineCount.autoresizingMask = [.minXMargin]
        lineCount.tag = 200
        bar.addSubview(lineCount)

        window.contentView?.addSubview(bar)

        // Separator
        let sep = NSBox(frame: NSRect(x: 0, y: barHeight, width: 700, height: 1))
        sep.boxType = .separator
        sep.autoresizingMask = [.width]
        window.contentView?.addSubview(sep)

        // Scroll view (above toolbar)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: barHeight + 1, width: 700, height: 500 - barHeight - 1))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        logTextView = NSTextView(frame: scrollView.bounds)
        logTextView.autoresizingMask = [.width]
        logTextView.isEditable = false
        logTextView.backgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.18, alpha: 1.0)
        logTextView.textColor = NSColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1.0)
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        logTextView.textContainerInset = NSSize(width: 10, height: 10)

        scrollView.documentView = logTextView
        window.contentView?.addSubview(scrollView)

        logWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        loadExistingLogs()
        startLogMonitoring()
    }

    @objc func saveLogs() {
        let panel = NSSavePanel()
        panel.title = "Save Logs"
        panel.nameFieldStringValue = "remote-claude-\(logTimestamp()).txt"
        panel.allowedContentTypes = [.plainText]

        guard let w = logWindow else { return }
        panel.beginSheetModal(for: w) { response in
            guard response == .OK, let url = panel.url else { return }
            // Use the raw log file content (plain text, no ANSI codes)
            let content = (try? String(contentsOfFile: LOG_FILE, encoding: .utf8)) ?? ""
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func logTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    @objc func clearLogs() {
        try? "".write(toFile: LOG_FILE, atomically: true, encoding: .utf8)
        if let tv = logTextView {
            tv.textStorage?.setAttributedString(NSAttributedString(string: ""))
        }
        updateLogLineCount()
    }

    func loadExistingLogs() {
        guard let content = try? String(contentsOfFile: LOG_FILE, encoding: .utf8) else { return }
        appendColoredLog(content)
    }

    func startLogMonitoring() {
        stopLogMonitoring()
        guard FileManager.default.fileExists(atPath: LOG_FILE) else { return }
        guard let fh = FileHandle(forReadingAtPath: LOG_FILE) else { return }
        fh.seekToEndOfFile()
        logFileHandle = fh

        let fd = fh.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in
            let data = fh.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                self?.appendColoredLog(str)
            }
        }
        source.setCancelHandler { fh.closeFile() }
        source.resume()
        logMonitorSource = source
    }

    func stopLogMonitoring() {
        logMonitorSource?.cancel()
        logMonitorSource = nil
        logFileHandle = nil
    }

    func appendColoredLog(_ text: String) {
        guard let tv = logTextView else { return }
        let storage = tv.textStorage!
        for line in text.components(separatedBy: "\n") {
            if line.isEmpty { continue }
            var color = NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1.0)
            if line.contains("ERROR") || line.contains("FATAL") {
                color = NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
            } else if line.contains("WARN") {
                color = NSColor(red: 0.9, green: 0.8, blue: 0.3, alpha: 1.0)
            } else if line.contains("CONN") {
                color = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 1.0)
            } else if line.contains("DISC") {
                color = NSColor(red: 0.9, green: 0.7, blue: 0.3, alpha: 1.0)
            } else if line.contains("START") {
                color = NSColor(red: 0.4, green: 0.8, blue: 0.95, alpha: 1.0)
            } else if line.contains("INFO") {
                color = NSColor(red: 0.78, green: 0.63, blue: 1.0, alpha: 1.0)
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            ]
            storage.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        scrollLogToBottom()
        updateLogLineCount()
    }

    func scrollLogToBottom() {
        guard let tv = logTextView else { return }
        tv.scrollToEndOfDocument(nil)
    }

    func updateLogLineCount() {
        guard let tv = logTextView,
              let label = logWindow?.contentView?.viewWithTag(200) as? NSTextField else { return }
        let text = tv.string
        let lines = text.components(separatedBy: "\n").count - 1
        let bytes = text.utf8.count
        if bytes > 1024 * 1024 {
            label.stringValue = "\(lines) lines  ·  \(String(format: "%.1f", Double(bytes) / 1048576.0)) MB"
        } else if bytes > 1024 {
            label.stringValue = "\(lines) lines  ·  \(bytes / 1024) KB"
        } else {
            label.stringValue = "\(lines) lines"
        }
    }

    func appendToLog(_ text: String) {
        if let fh = FileHandle(forWritingAtPath: LOG_FILE) {
            fh.seekToEndOfFile()
            fh.write(text.data(using: .utf8)!)
            fh.closeFile()
        }
    }

    // ─── QR Code ────────────────────────────────────────────────
    func generateQRCode(from string: String) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }

        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let size = 260
        let nsImage = NSImage(size: NSSize(width: size, height: size))
        nsImage.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        nsImage.unlockFocus()
        return nsImage
    }

    @objc func showQRCode() {
        if let w = qrWindow { w.close(); qrWindow = nil }

        let url = getServerURL()
        guard let qrImage = generateQRCode(from: url) else {
            let alert = NSAlert()
            alert.messageText = "Failed to generate QR code"
            alert.runModal()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Remote Claude — Connect"
        window.center()
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white

        let content = NSView(frame: window.contentView!.bounds)

        let urlLabel = NSTextField(labelWithString: url)
        urlLabel.font = NSFont.monospacedSystemFont(ofSize: 16, weight: .bold)
        urlLabel.alignment = .center
        urlLabel.isSelectable = true
        urlLabel.frame = NSRect(x: 10, y: 358, width: 300, height: 28)
        content.addSubview(urlLabel)

        let hint = NSTextField(labelWithString: "Scan with your phone camera")
        hint.font = NSFont.systemFont(ofSize: 13)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.frame = NSRect(x: 10, y: 332, width: 300, height: 20)
        content.addSubview(hint)

        let imageView = NSImageView(frame: NSRect(x: 30, y: 55, width: 260, height: 260))
        imageView.image = qrImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        content.addSubview(imageView)

        let copyBtn = NSButton(frame: NSRect(x: 90, y: 12, width: 140, height: 32))
        copyBtn.title = "Copy URL"
        copyBtn.bezelStyle = .rounded
        copyBtn.target = self
        copyBtn.action = #selector(copyURLFromQR(_:))
        content.addSubview(copyBtn)

        window.contentView = content
        qrWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func copyURLFromQR(_ sender: NSButton) {
        copyURL()
        let original = sender.title
        sender.title = "Copied!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.title = original }
    }

    // ─── Gemini API Key ─────────────────────────────────────────
    func isGeminiKeyConfigured() -> Bool {
        guard let content = try? String(contentsOfFile: GEMINI_KEY_FILE, encoding: .utf8) else { return false }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func updateGeminiKeyStatus() {
        geminiKeyMenuItem.title = isGeminiKeyConfigured()
            ? "Gemini API Key: Set"
            : "Gemini API Key: Not Set"
    }

    @objc func setGeminiKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API Key"
        alert.informativeText = "Enter your key from aistudio.google.com\nRestart the server after changing the key."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "AIza..."
        input.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        if let existing = try? String(contentsOfFile: GEMINI_KEY_FILE, encoding: .utf8) {
            input.stringValue = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        alert.window.makeFirstResponder(input)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                try? FileManager.default.removeItem(atPath: GEMINI_KEY_FILE)
            } else {
                try? key.write(toFile: GEMINI_KEY_FILE, atomically: true, encoding: .utf8)
            }
            updateGeminiKeyStatus()
        }
    }

    // ─── Projects Folder ─────────────────────────────────────────
    func getProjectsRoot() -> String {
        if let content = try? String(contentsOfFile: PROJECTS_CONFIG_FILE, encoding: .utf8) {
            let path = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return PROJECTS_ROOT_DEFAULT
    }

    func updateProjectsPathStatus() {
        let path = getProjectsRoot()
        let display = (path as NSString).abbreviatingWithTildeInPath
        projectsPathMenuItem.title = "Projects Folder: \(display)"
    }

    @objc func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Projects Folder"
        panel.message = "Select the folder that contains your projects.\nRestart the server after changing this."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: getProjectsRoot())

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()

        if response == .OK, let url = panel.url {
            try? url.path.write(toFile: PROJECTS_CONFIG_FILE, atomically: true, encoding: .utf8)
            updateProjectsPathStatus()
        }
    }

    // ─── Actions ────────────────────────────────────────────────
    @objc func copyURL() {
        let url = getServerURL()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(URL(string: "https://localhost:\(PORT)")!)
    }

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Remote Claude"
        alert.informativeText = "Access Claude Code from your phone.\n\nBy Mads Vejen Langkilde\n\nVersion 1.0"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }

    // ─── Onboarding ─────────────────────────────────────────────

    // -- UI helpers --

    func obLabel(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                 color: NSColor = .labelColor, width: CGFloat = 490) -> NSTextField {
        let tf = NSTextField(wrappingLabelWithString: text)
        tf.font = NSFont.systemFont(ofSize: size, weight: weight)
        tf.textColor = color
        tf.isEditable = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.preferredMaxLayoutWidth = width
        tf.frame.size.width = width
        if let cell = tf.cell {
            tf.frame.size.height = cell.cellSize(
                forBounds: NSRect(x: 0, y: 0, width: width, height: 10000)).height
        }
        return tf
    }

    func obStatusRow(_ ok: Bool, _ name: String, _ detail: String = "") -> NSView {
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 20))
        let icon = NSTextField(labelWithString: ok ? "\u{2713}" : "\u{2717}")
        icon.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        icon.textColor = ok ? .systemGreen : .systemRed
        icon.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        row.addSubview(icon)

        let lbl = NSTextField(labelWithString: name)
        lbl.font = NSFont.systemFont(ofSize: 13)
        lbl.frame = NSRect(x: 24, y: 0, width: 240, height: 20)
        row.addSubview(lbl)

        if !detail.isEmpty {
            let d = NSTextField(labelWithString: detail)
            d.font = NSFont.systemFont(ofSize: 11)
            d.textColor = .secondaryLabelColor
            d.alignment = .right
            d.frame = NSRect(x: 270, y: 0, width: 220, height: 20)
            row.addSubview(d)
        }
        return row
    }

    func obButton(_ title: String, action: Selector, tag: Int = 0) -> NSButton {
        let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        btn.title = title
        btn.bezelStyle = .rounded
        btn.target = self
        btn.action = action
        btn.tag = tag
        return btn
    }

    func obSpacer(_ h: CGFloat = 6) -> NSView {
        return NSView(frame: NSRect(x: 0, y: 0, width: 490, height: h))
    }

    func obLayout(title: String, elements: [NSView]) -> NSView {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 435))

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.drawsBackground = false
        titleLabel.frame = NSRect(x: 35, y: 390, width: 490, height: 35)
        page.addSubview(titleLabel)

        var y: CGFloat = 378
        for el in elements {
            let h = max(el.frame.height, 18)
            y -= h
            el.frame.origin = NSPoint(x: 35, y: y)
            if el.frame.width < 1 { el.frame.size.width = 490 }
            page.addSubview(el)
            y -= 6
        }
        return page
    }

    // -- Prerequisite checks --

    func checkNodeInstalled() -> Bool {
        FileManager.default.fileExists(atPath: NODE_PATH)
    }

    func checkClaudeInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "\(HOME)/.local/bin/claude")
    }

    func checkDepsInstalled() -> Bool {
        FileManager.default.fileExists(atPath: "\(PROJECT_DIR)/node_modules/node-pty")
    }

    func checkSpawnHelper() -> Bool {
        let path = "\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
        return FileManager.default.isExecutableFile(atPath: path)
    }

    func checkCertsExist() -> Bool {
        FileManager.default.fileExists(atPath: "\(PROJECT_DIR)/certs/cert.pem") &&
        FileManager.default.fileExists(atPath: "\(PROJECT_DIR)/certs/key.pem")
    }

    func getCertIP() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = ["x509", "-in", "\(PROJECT_DIR)/certs/cert.pem", "-noout", "-ext", "subjectAltName"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if let range = output.range(of: "IP Address:") {
                let rest = output[range.upperBound...]
                let ip = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: CharacterSet.newlines).first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                return ip.isEmpty ? nil : ip
            }
        } catch {}
        return nil
    }

    // -- Window scaffolding --

    @objc func showOnboarding() {
        if let w = onboardingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Remote Claude — Setup"
        window.center()
        window.isReleasedWhenClosed = false

        let root = NSView(frame: window.contentView!.bounds)

        // Content area (pages go here)
        onboardingContentArea = NSView(frame: NSRect(x: 0, y: 55, width: 560, height: 445))
        root.addSubview(onboardingContentArea)

        // Separator
        let sep = NSBox(frame: NSRect(x: 0, y: 54, width: 560, height: 1))
        sep.boxType = .separator
        root.addSubview(sep)

        // Navigation bar
        onboardingBackBtn = NSButton(frame: NSRect(x: 20, y: 12, width: 100, height: 32))
        onboardingBackBtn.title = "Back"
        onboardingBackBtn.bezelStyle = .rounded
        onboardingBackBtn.target = self
        onboardingBackBtn.action = #selector(onboardingBack)
        root.addSubview(onboardingBackBtn)

        onboardingStepLabel = NSTextField(labelWithString: "")
        onboardingStepLabel.font = NSFont.systemFont(ofSize: 12)
        onboardingStepLabel.textColor = .secondaryLabelColor
        onboardingStepLabel.alignment = .center
        onboardingStepLabel.frame = NSRect(x: 180, y: 18, width: 200, height: 18)
        root.addSubview(onboardingStepLabel)

        onboardingNextBtn = NSButton(frame: NSRect(x: 440, y: 12, width: 100, height: 32))
        onboardingNextBtn.title = "Continue"
        onboardingNextBtn.bezelStyle = .rounded
        onboardingNextBtn.keyEquivalent = "\r"
        onboardingNextBtn.target = self
        onboardingNextBtn.action = #selector(onboardingNext)
        root.addSubview(onboardingNextBtn)

        window.contentView = root
        onboardingWindow = window

        onboardingPage = 0
        renderOnboardingPage()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func renderOnboardingPage() {
        // Clear content area
        for sub in onboardingContentArea.subviews { sub.removeFromSuperview() }

        // Build current page
        let page: NSView
        switch onboardingPage {
        case 0: page = pageWelcome()
        case 1: page = pageRequirements()
        case 2: page = pageNetwork()
        case 3: page = pageCertificate()
        case 4: page = pageVoice()
        case 5: page = pageReady()
        default: page = NSView()
        }
        onboardingContentArea.addSubview(page)

        // Update navigation
        onboardingBackBtn.isHidden = (onboardingPage == 0)
        onboardingStepLabel.stringValue = "Step \(onboardingPage + 1) of \(onboardingPageCount)"

        if onboardingPage == onboardingPageCount - 1 {
            onboardingNextBtn.title = "Start Server"
            onboardingNextBtn.action = #selector(finishOnboarding)
        } else {
            onboardingNextBtn.title = "Continue"
            onboardingNextBtn.action = #selector(onboardingNext)
        }
    }

    @objc func onboardingBack() {
        if onboardingPage > 0 {
            onboardingPage -= 1
            renderOnboardingPage()
        }
    }

    @objc func onboardingNext() {
        if onboardingPage < onboardingPageCount - 1 {
            onboardingPage += 1
            renderOnboardingPage()
        }
    }

    @objc func finishOnboarding() {
        try? "done".write(toFile: ONBOARDING_FILE, atomically: true, encoding: .utf8)
        onboardingWindow?.close()
        onboardingWindow = nil

        if !isServerRunning() {
            startServer()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkStatus()
            self?.showQRCode()
        }
    }

    // -- Page 0: Welcome --

    func pageWelcome() -> NSView {
        return obLayout(title: "Welcome to Remote Claude", elements: [
            obSpacer(4),
            obLabel(
                "Remote Claude lets you use Claude Code from your phone — anywhere, anytime.",
                size: 14),
            obSpacer(8),
            obLabel(
                "Talk to Claude with your voice, approve file changes on the go, " +
                "and manage all your projects from a mobile-friendly terminal.",
                size: 13, color: .secondaryLabelColor),
            obSpacer(16),
            obLabel("What you'll set up:", size: 13, weight: .semibold),
            obSpacer(2),
            obLabel(
                "  1.  Node.js and Claude Code (the core tools)\n" +
                "  2.  A private network so your phone can reach your Mac\n" +
                "  3.  An HTTPS certificate for secure microphone access\n" +
                "  4.  A Gemini API key for hands-free voice mode",
                size: 13),
            obSpacer(16),
            obLabel(
                "It only takes a few minutes. You can re-open this guide\nanytime from the menu bar.",
                size: 12, color: .tertiaryLabelColor),
        ])
    }

    // -- Page 1: Requirements --

    func pageRequirements() -> NSView {
        let hasNode = checkNodeInstalled()
        let hasClaude = checkClaudeInstalled()
        let hasDeps = checkDepsInstalled()
        let hasSpawn = checkSpawnHelper()

        var items: [NSView] = [
            obSpacer(4),
            obLabel("Remote Claude needs these tools installed on your Mac:", size: 13),
            obSpacer(8),
            obStatusRow(hasNode, "Node.js", hasNode ? NODE_PATH : "Not found"),
            obStatusRow(hasClaude, "Claude Code CLI", hasClaude ? "~/.local/bin/claude" : "Not found"),
            obStatusRow(hasDeps, "npm dependencies", hasDeps ? "Installed" : "Not installed"),
        ]

        if hasDeps {
            items.append(obStatusRow(hasSpawn, "node-pty spawn helper", hasSpawn ? "Executable" : "Not executable"))
        }

        items.append(obSpacer(12))

        if !hasNode {
            items.append(obLabel(
                "Install Node.js (v18+) from nodejs.org or via Homebrew:\n  brew install node",
                size: 12, color: .secondaryLabelColor))
            items.append(obSpacer(4))
        }

        if !hasClaude {
            items.append(obLabel(
                "Install Claude Code:\n  npm install -g @anthropic-ai/claude-code",
                size: 12, color: .secondaryLabelColor))
            items.append(obSpacer(4))
        }

        if !hasDeps && hasNode {
            items.append(obButton("Install Dependencies", action: #selector(obInstallDeps), tag: 101))
        } else if hasDeps && !hasSpawn {
            items.append(obButton("Fix Permissions", action: #selector(obFixSpawnHelper)))
        }

        return obLayout(title: "Requirements", elements: items)
    }

    @objc func obInstallDeps() {
        if let btn = onboardingContentArea.viewWithTag(101) as? NSButton {
            btn.isEnabled = false
            btn.title = "Installing..."
        }
        DispatchQueue.global().async { [weak self] in
            let npmPaths = ["/usr/local/bin/npm", "/opt/homebrew/bin/npm"]
            var npmPath: String?
            for p in npmPaths { if FileManager.default.fileExists(atPath: p) { npmPath = p; break } }
            guard let npm = npmPath else { return }

            let task = Process()
            task.executableURL = URL(fileURLWithPath: npm)
            task.arguments = ["install"]
            task.currentDirectoryURL = URL(fileURLWithPath: PROJECT_DIR)
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()

            // Fix spawn-helper permissions
            let helper = "\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
            if FileManager.default.fileExists(atPath: helper) { chmod(helper, 0o755) }

            DispatchQueue.main.async { self?.renderOnboardingPage() }
        }
    }

    @objc func obFixSpawnHelper() {
        let helper = "\(PROJECT_DIR)/node_modules/node-pty/prebuilds/darwin-arm64/spawn-helper"
        chmod(helper, 0o755)
        renderOnboardingPage()
    }

    // -- Page 2: Network / VPN --

    func pageNetwork() -> NSView {
        let ip = getTailscaleIP()
        let hasTailscale = ip != nil

        var items: [NSView] = [
            obSpacer(4),
            obLabel(
                "To use Claude from your phone, both devices need to be on the same " +
                "private network. A regular home Wi-Fi works if both are connected, " +
                "but won't work when you're away from home.",
                size: 13),
            obSpacer(10),
            obLabel("We recommend Tailscale", size: 14, weight: .semibold),
            obSpacer(2),
            obLabel(
                "Tailscale is a free, zero-config VPN that creates a secure " +
                "encrypted tunnel between your devices — no matter where they are. " +
                "It works through firewalls and NATs without opening any ports.",
                size: 13, color: .secondaryLabelColor),
            obSpacer(8),
            obLabel(
                "  1.  Install Tailscale on your Mac  (tailscale.com/download)\n" +
                "  2.  Install Tailscale on your phone  (App Store / Play Store)\n" +
                "  3.  Sign in with the same account on both\n" +
                "  4.  Done — they can now reach each other securely",
                size: 13),
            obSpacer(12),
            obStatusRow(hasTailscale, "Tailscale", hasTailscale ? "Connected: \(ip!)" : "Not detected"),
        ]

        if !hasTailscale {
            items.append(obSpacer(4))
            items.append(obButton("Open tailscale.com", action: #selector(obOpenTailscale)))
            items.append(obSpacer(8))
            items.append(obLabel(
                "You can also use any other VPN or network setup that " +
                "gives both devices a route to each other.",
                size: 12, color: .tertiaryLabelColor))
        }

        return obLayout(title: "Secure Remote Access", elements: items)
    }

    @objc func obOpenTailscale() {
        NSWorkspace.shared.open(URL(string: "https://tailscale.com/download")!)
    }

    // -- Page 3: HTTPS Certificate --

    func pageCertificate() -> NSView {
        let hasCert = checkCertsExist()
        let certIP = hasCert ? getCertIP() : nil
        let tailscaleIP = getTailscaleIP()

        var items: [NSView] = [
            obSpacer(4),
            obLabel(
                "Mobile browsers require HTTPS for microphone access, which " +
                "powers the voice assistant. A self-signed certificate is " +
                "generated for your network IP address.",
                size: 13),
            obSpacer(4),
            obLabel(
                "When you first visit the URL on your phone, the browser " +
                "will show a certificate warning. This is normal for self-signed " +
                "certificates — tap \"Advanced\" and proceed. This only happens once.",
                size: 12, color: .secondaryLabelColor),
            obSpacer(12),
        ]

        if hasCert {
            if let cip = certIP {
                items.append(obStatusRow(true, "Certificate found", "IP: \(cip)"))
                if let tip = tailscaleIP, cip != tip {
                    items.append(obStatusRow(false, "IP mismatch", "Tailscale is \(tip)"))
                    items.append(obSpacer(4))
                    items.append(obLabel(
                        "Your certificate was issued for a different IP. " +
                        "Regenerate it to match your current Tailscale address.",
                        size: 12, color: .systemOrange))
                    items.append(obSpacer(4))
                    items.append(obButton("Regenerate Certificate", action: #selector(obGenerateCert)))
                }
            } else {
                items.append(obStatusRow(true, "Certificate found", ""))
            }
        } else {
            items.append(obStatusRow(false, "No certificate", ""))
            items.append(obSpacer(4))
            if tailscaleIP != nil {
                items.append(obButton("Generate Certificate", action: #selector(obGenerateCert)))
            } else {
                items.append(obLabel(
                    "Set up Tailscale first (previous step) so the certificate " +
                    "can be issued for your Tailscale IP.",
                    size: 12, color: .systemOrange))
            }
        }

        return obLayout(title: "HTTPS Certificate", elements: items)
    }

    @objc func obGenerateCert() {
        guard let ip = getTailscaleIP() else {
            let alert = NSAlert()
            alert.messageText = "Tailscale Not Detected"
            alert.informativeText = "Connect to Tailscale first so the certificate can use your Tailscale IP."
            alert.runModal()
            return
        }

        let certsDir = "\(PROJECT_DIR)/certs"
        try? FileManager.default.createDirectory(atPath: certsDir, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        task.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", "\(certsDir)/key.pem",
            "-out", "\(certsDir)/cert.pem",
            "-days", "365", "-nodes",
            "-subj", "/CN=remote-claude",
            "-addext", "subjectAltName=IP:\(ip)"
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                renderOnboardingPage()
            }
        } catch {}
    }

    // -- Page 4: Voice Mode --

    func pageVoice() -> NSView {
        let hasKey = isGeminiKeyConfigured()

        return obLayout(title: "Voice Mode (Optional)", elements: [
            obSpacer(4),
            obLabel(
                "Voice mode lets you talk to Claude hands-free. Google Gemini " +
                "acts as an intelligent voice bridge — it translates your speech " +
                "into terminal commands and reads Claude's responses back to you.",
                size: 13),
            obSpacer(8),
            obLabel(
                "To enable voice mode, you need a free Gemini API key:",
                size: 13),
            obSpacer(2),
            obLabel(
                "  1.  Visit aistudio.google.com\n" +
                "  2.  Click \"Get API Key\" and create one\n" +
                "  3.  Click the button below to save it",
                size: 13),
            obSpacer(12),
            obStatusRow(hasKey, "Gemini API Key", hasKey ? "Configured" : "Not set"),
            obSpacer(6),
            obButton(hasKey ? "Change API Key..." : "Set API Key...", action: #selector(obSetGeminiKey)),
            obSpacer(16),
            obLabel(
                "Voice mode is optional — you can skip this and always use " +
                "the terminal directly. You can set the key later from the menu bar.",
                size: 12, color: .tertiaryLabelColor),
        ])
    }

    @objc func obSetGeminiKey() {
        setGeminiKey()
        renderOnboardingPage()
    }

    // -- Page 5: Ready --

    func pageReady() -> NSView {
        let hasNode = checkNodeInstalled()
        let hasClaude = checkClaudeInstalled()
        let hasDeps = checkDepsInstalled()
        let ip = getTailscaleIP()
        let hasCert = checkCertsExist()
        let hasKey = isGeminiKeyConfigured()
        let running = isServerRunning()

        var items: [NSView] = [
            obSpacer(4),
            obStatusRow(hasNode, "Node.js", hasNode ? "Installed" : "Missing"),
            obStatusRow(hasClaude, "Claude Code", hasClaude ? "Installed" : "Missing"),
            obStatusRow(hasDeps, "Dependencies", hasDeps ? "Installed" : "Missing"),
            obStatusRow(ip != nil, "Tailscale", ip != nil ? ip! : "Not connected"),
            obStatusRow(hasCert, "HTTPS Certificate", hasCert ? "Ready" : "Missing"),
            obStatusRow(hasKey, "Gemini API Key", hasKey ? "Configured" : "Not set (voice disabled)"),
            obSpacer(14),
        ]

        if running {
            items.append(obLabel(
                "Your server is already running! Click below to see the " +
                "QR code and connect your phone.",
                size: 13))
        } else {
            items.append(obLabel(
                "Click \"Start Server\" to launch Remote Claude. A QR code " +
                "will appear — scan it with your phone's camera to connect.",
                size: 13))
        }

        items.append(obSpacer(12))
        items.append(obLabel(
            "You can re-open this guide anytime from the menu bar " +
            "under \"Setup Guide...\"",
            size: 12, color: .tertiaryLabelColor))

        return obLayout(title: "You're All Set!", elements: items)
    }
}

// ─── Insecure URL delegate (for self-signed cert) ───────────────
class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// ─── Main ───────────────────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no dock icon
app.run()
