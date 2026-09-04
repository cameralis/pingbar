import AppKit
import ServiceManagement

// MARK: - Ping source

/// Runs one long lived `ping -i 1 <host>` process and reports each reply.
/// The process is restarted automatically if it dies (network change, sleep/wake).
final class PingMonitor {

    enum Sample {
        case reply(Double)   // round trip time in milliseconds
        case lost            // request timeout / unreachable
    }

    let host: String
    var onSample: ((Sample) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var stopped = false
    private let queue = DispatchQueue(label: "pingbar.monitor")

    init(host: String) {
        self.host = host
    }

    func start() {
        stopped = false
        launch()
    }

    func stop() {
        stopped = true
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    func restart() {
        stop()
        start()
    }

    private func launch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/ping")
        // -i 1  : one probe per second
        // -n    : no reverse DNS, keeps the output format stable
        task.arguments = ["-i", "1", "-n", host]

        let out = Pipe()
        task.standardOutput = out
        task.standardError = out

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }

        task.terminationHandler = { [weak self] _ in
            guard let self, !self.stopped else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard !self.stopped else { return }
                self.launch()
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.stopped else { return }
                self.launch()
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let sample = Self.parse(line) {
                DispatchQueue.main.async { [weak self] in self?.onSample?(sample) }
            }
        }
    }

    /// "64 bytes from 1.1.1.1: icmp_seq=390 ttl=46 time=43.251 ms" -> .reply(43.251)
    /// "Request timeout for icmp_seq 391"                          -> .lost
    static func parse(_ line: String) -> Sample? {
        if let range = line.range(of: "time="), line.hasSuffix(" ms") || line.contains(" ms") {
            let rest = line[range.upperBound...]
            let digits = rest.prefix { $0.isNumber || $0 == "." }
            if let value = Double(digits) { return .reply(value) }
        }
        if line.contains("Request timeout")
            || line.contains("Destination Host Unreachable")
            || line.contains("No route to host")
            || line.contains("cannot resolve")
            || line.contains("Network is unreachable") {
            return .lost
        }
        return nil
    }
}

// MARK: - Status bar app

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var monitor: PingMonitor?
    private var lastSampleAt = Date.distantPast
    private var watchdog: Timer?

    private var host: String {
        UserDefaults.standard.string(forKey: "host") ?? "1.1.1.1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        render(text: "...", warning: false)
        buildMenu()
        startMonitor()

        // A probe every second: if nothing arrives for 3 s the link is down.
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSampleAt) > 3 {
                self.render(text: "-- ms", warning: true)
            }
        }

        // ping keeps running across sleep, but the socket is often dead on wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.monitor?.restart()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    private func startMonitor() {
        monitor?.stop()
        let m = PingMonitor(host: host)
        m.onSample = { [weak self] sample in
            guard let self else { return }
            self.lastSampleAt = Date()
            switch sample {
            case .reply(let ms):
                self.render(text: "\(Int(ms.rounded())) ms", warning: false)
            case .lost:
                self.render(text: "-- ms", warning: true)
            }
        }
        m.start()
        monitor = m
    }

    private func render(text: String, warning: Bool) {
        guard let button = statusItem.button else { return }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: warning ? NSColor.systemRed : NSColor.labelColor,
            ]
        )
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()

        let hosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9", "apple.com"]
        var known = hosts
        if !known.contains(host) { known.insert(host, at: 0) }
        for candidate in known {
            let item = NSMenuItem(title: candidate, action: #selector(selectHost(_:)), keyEquivalent: "")
            item.target = self
            item.state = (candidate == host) ? .on : .off
            menu.addItem(item)
        }

        let custom = NSMenuItem(title: "Other Host...", action: #selector(promptForHost), keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit PingBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func selectHost(_ sender: NSMenuItem) {
        setHost(sender.title)
    }

    @objc private func promptForHost() {
        let alert = NSAlert()
        alert.messageText = "Ping host"
        alert.informativeText = "Host name or IP address to ping every second."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = host
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        setHost(value)
    }

    private func setHost(_ value: String) {
        UserDefaults.standard.set(value, forKey: "host")
        render(text: "...", warning: false)
        lastSampleAt = Date()
        startMonitor()
        buildMenu()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not change the login item."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        buildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
