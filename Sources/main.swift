import AppKit
import Network
import ServiceManagement

// MARK: - Ping source

/// Runs one long lived `ping -i 1 <host>` process and reports each reply.
/// The process is restarted when it dies, when the network path changes,
/// and when it stops giving replies (a stale ICMP socket after a route change).
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
    private var generation = 0          // ignores output from a replaced process
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
        generation &+= 1
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        queue.async { [weak self] in self?.buffer.removeAll() }
    }

    func restart() {
        stop()
        start()
    }

    private func launch() {
        generation &+= 1
        let gen = generation

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
            guard !data.isEmpty else {
                // End of file. Without this the handler fires in a tight loop.
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data, gen: gen) }
        }

        task.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            self?.relaunchAfterFailure(gen: gen)
        }

        do {
            try task.run()
            process = task
        } catch {
            relaunchAfterFailure(gen: gen)
        }
    }

    private func relaunchAfterFailure(gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.stopped, gen == self.generation else { return }
            self.launch()
        }
    }

    private func consume(_ data: Data, gen: Int) {
        guard gen == generation else { return }
        buffer.append(data)
        while let idx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            if let sample = Self.parse(line) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.generation else { return }
                    self.onSample?(sample)
                }
            }
        }
    }

    /// "64 bytes from 1.1.1.1: icmp_seq=390 ttl=46 time=43.251 ms" -> .reply(43.251)
    /// "Request timeout for icmp_seq 391"                          -> .lost
    static func parse(_ line: String) -> Sample? {
        if let range = line.range(of: "time=") {
            let digits = line[range.upperBound...].prefix { $0.isNumber || $0 == "." }
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

    /// Show the red placeholder after this many seconds with no reply.
    private let staleAfter: TimeInterval = 3
    /// Restart the ping process after this many seconds with no reply.
    private let restartAfter: TimeInterval = 8
    /// Never restart more often than this.
    private let restartCooldown: TimeInterval = 15
    /// A reply slower than this many milliseconds makes the dot yellow.
    private var slowAbove: Double {
        let value = UserDefaults.standard.double(forKey: "slowAboveMs")
        return value > 0 ? value : 100
    }

    /// The colour of the dot in front of the value.
    private enum Health {
        case unknown    // no measurement yet
        case good       // a fast reply
        case slow       // a slow reply
        case down       // no reply

        var color: NSColor {
            switch self {
            case .unknown: return .tertiaryLabelColor
            case .good:    return .systemGreen
            case .slow:    return .systemYellow
            case .down:    return .systemRed
            }
        }
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var monitor: PingMonitor?
    private var lastSampleAt = Date.distantPast
    private var lastRestartAt = Date.distantPast
    private var watchdog: Timer?
    private let pathMonitor = NWPathMonitor()
    private var lastPathKey: String?

    private var host: String {
        UserDefaults.standard.string(forKey: "host") ?? "1.1.1.1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        render(text: "...", health: .unknown)
        buildMenu()
        startMonitor()

        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkForStall()
        }

        // A route change (Wi-Fi switch, VPN, cable) leaves the open ICMP socket
        // on the old path. The process then reports timeouts until it is replaced.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let key = path.availableInterfaces.map(\.name).joined(separator: ",") + "|\(path.status)"
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.lastPathKey = key }
                guard self.lastPathKey != nil, self.lastPathKey != key else { return }
                self.restartMonitor(force: true)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "pingbar.path"))

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.restartMonitor(force: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    // MARK: Monitor control

    private func startMonitor() {
        monitor?.stop()
        let m = PingMonitor(host: host)
        m.onSample = { [weak self] sample in
            guard let self else { return }
            self.lastSampleAt = Date()
            switch sample {
            case .reply(let ms):
                self.render(text: "\(Int(ms.rounded())) ms", health: ms > self.slowAbove ? .slow : .good)
            case .lost:
                break   // the watchdog decides when the value is too old
            }
        }
        m.start()
        monitor = m
        lastRestartAt = Date()
    }

    private func restartMonitor(force: Bool) {
        if !force, Date().timeIntervalSince(lastRestartAt) < restartCooldown { return }
        lastRestartAt = Date()
        monitor?.restart()
    }

    private func checkForStall() {
        let age = Date().timeIntervalSince(lastSampleAt)
        if age > staleAfter {
            render(text: "-- ms", health: .down)
        }
        // No reply for a long time, but the process is alive: replace it.
        if age > restartAfter {
            restartMonitor(force: false)
        }
    }

    private func render(text: String, health: Health) {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString(
            string: "\u{25CF} ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: health.color,
                .baselineOffset: 1.0,
            ]
        )
        title.append(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        button.attributedTitle = title
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

        let restart = NSMenuItem(title: "Restart Ping", action: #selector(restartNow), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)

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

    @objc private func restartNow() {
        render(text: "...", health: .unknown)
        lastSampleAt = Date()
        restartMonitor(force: true)
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
        render(text: "...", health: .unknown)
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
