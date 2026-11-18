import SwiftUI
import Network
import ServiceManagement
import RGPCore
import RGPMirror

/// CoastPlay Host: shares this Mac's screen and sound with the paired phone and accepts control.
/// Local network only. Nothing is recorded or uploaded.
@main
struct HostApp: App {
    @StateObject private var host = MirrorHost()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("CoastPlay Host") {
            VStack(alignment: .leading, spacing: 10) {
                Text("CoastPlay Host").font(.title2.bold())
                Text(host.status).foregroundStyle(host.isError ? .red : .primary).fixedSize(horizontal: false, vertical: true)
                Divider()
                // Setup, in the order a new person needs it. Each line shows whether it is done
                // and offers the one button that does it.
                Text("SET UP").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                SetupStep(done: host.sharing, title: "1. Allow screen sharing",
                          detail: host.sharing ? "Allowed." : "Your Mac will ask. Click Allow. If it didn't ask, press the button below, switch on CoastPlay Host, then open this app again.",
                          button: host.sharing ? nil : "Open the setting") { host.openPrivacy("Privacy_ScreenCapture") }
                SetupStep(done: host.canControl, title: "2. Allow control from your phone",
                          detail: host.canControl ? "Allowed." : "Press the button and switch on CoastPlay Host. Without this your phone can watch but not click or type.",
                          button: host.canControl ? nil : "Allow control") { host.requestControl() }
                SetupStep(done: host.pairedOnce, title: "3. Connect your phone",
                          detail: "On your phone, open CoastPlay PRO, tap Devices, add a computer, and type this code. Use the same Wi-Fi as this Mac.", button: nil) {}
                Text(host.formattedCode).font(.system(size: 30, weight: .bold, design: .monospaced)).textSelection(.enabled).padding(.leading, 26)
                SetupStep(done: host.openAtLogin && host.keepAwake, title: "4. Keep it ready",
                          detail: "Your phone can only connect while this app is open and this Mac is awake. That is true at home and away. Switch both on so it is always ready.", button: nil) {}
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Open this app when I turn on my Mac", isOn: $host.openAtLogin)
                    Toggle("Keep my Mac awake while this app is open", isOn: $host.keepAwake)
                    if let note = host.readyNote { Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(.leading, 26)
                SetupStep(done: host.awayReached, title: "5. Use it away from home (optional)",
                          detail: "One change on your Wi-Fi router lets your phone reach this Mac from anywhere. Do it yourself or let an AI helper do it. Then connect once from your phone at home.",
                          button: nil) {}
                HStack {
                    Button("Open my router") { host.openRouter() }.disabled(host.routerAddress == nil)
                    Button("Copy for AI helper") { host.copyHelperPrompt() }
                    Button("Test it") { host.checkAway() }
                }
                .padding(.leading, 26)
                Text("Router setting: TCP port \(MirrorProtocol.awayPort) → \(host.localAddress). If your phone can't find this Mac at home, its address is \(host.addressText).")
                    .font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).padding(.leading, 26)
                if let note = host.awayNote { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 26) }
                Divider()
                Label(host.clientText, systemImage: host.clientConnected ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                Picker("A controller on the phone acts as", selection: $host.gameKeys) {
                    Text("Mouse (desktop)").tag(false)
                    Text("Game keys").tag(true)
                }
                .pickerStyle(.segmented)
                Text(host.gameKeys ? "Game keys: " + GameKeys.legend.map { "\($0.control) → \($0.sends)" }.joined(separator: "  ·  ")
                                   : "Left stick moves the pointer, right stick scrolls, Cross clicks, Circle right-clicks. You can switch this from the phone too.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Anyone with the pairing code on your network can see and control this Mac while this app is open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("New code (disconnects phones)") { host.regenerateCode() }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(20)
            .frame(width: 480)
            .onAppear { host.start() }
        }
        .windowResizability(.contentSize)
    }
}

/// One line of the setup list: a tick or an empty circle, what the step is, and its button.
struct SetupStep: View {
    let done: Bool
    let title: String
    let detail: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let button { Button(button, action: action) }
            }
        }
    }
}

@MainActor
final class MirrorHost: ObservableObject {
    // MARK: Setup helpers

    @Published var sharing = false
    @Published var pairedOnce = UserDefaults.standard.bool(forKey: "pairedOnce")
    @Published var awayReached = UserDefaults.standard.bool(forKey: "awayReached")
    @Published var readyNote: String?
    @Published var awayNote: String?
    @Published var localAddress = "this Mac"
    @Published var routerAddress: String?
    private var awakeToken: NSObjectProtocol?

    /// Starts this app at login. Uses the system's own login-items list, where the person can
    /// see it and switch it off (System Settings → General → Login Items).
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard openAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                readyNote = nil
            } catch {
                readyNote = "macOS would not change the login setting (\(error.localizedDescription)). You can add CoastPlay Host yourself in System Settings → General → Login Items."
                openAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    /// Stops the Mac going to sleep from being idle, only while this app is open. It cannot
    /// stop a laptop sleeping when its lid is closed on battery.
    @Published var keepAwake = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet { UserDefaults.standard.set(keepAwake, forKey: "keepAwake"); applyKeepAwake() }
    }

    private func applyKeepAwake() {
        if keepAwake, awakeToken == nil {
            awakeToken = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "CoastPlay Host is waiting for the phone")
        } else if !keepAwake, let token = awakeToken {
            ProcessInfo.processInfo.endActivity(token); awakeToken = nil
        }
    }

    func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// The router's address, as this Mac's network settings report it.
    private func findRouter() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/sbin/route")
        task.arguments = ["-n", "get", "default"]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if let line = text.split(separator: "\n").first(where: { $0.contains("gateway:") }) {
            let value = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if value.split(separator: ".").count == 4, value.allSatisfy({ $0.isNumber || $0 == "." }) { routerAddress = value }
        }
    }

    func openRouter() {
        if let routerAddress, let url = URL(string: "http://\(routerAddress)") { NSWorkspace.shared.open(url) }
    }

    /// Plain instructions a person can paste into an AI assistant that can work a browser.
    /// Contains no code, key or password.
    func copyHelperPrompt() {
        let text = """
        Help me add one port forward on my home router so I can use CoastPlay away from home.
        - Router page: http://\(routerAddress ?? "my router's address")
        - Add a rule named "CoastPlay Mac": protocol TCP, outside port \(MirrorProtocol.awayPort), inside port \(MirrorProtocol.awayPort), to the device at \(localAddress) (this Mac).
        - On many routers this is under Firewall, NAT, Gaming, Port Forwarding or Virtual Server. Some routers need two steps: create the service, then assign it to the device.
        - If the router asks for its admin password or access code, stop and ask me to type it myself. Do not change any other setting.
        - When it is saved, tell me, and I will press "Check it" in CoastPlay Host.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        awayNote = "Copied. Paste it into your AI assistant. It contains no code or password."
    }

    /// Asks a public "what is my address" service for the home's internet address, then tries
    /// the away port on it. From inside the home some routers refuse this even when the forward
    /// is right, so a failure here is not proof; the real test is the phone on mobile data.
    func checkAway() {
        awayNote = "Checking…"
        Task {
            guard let url = URL(string: "https://api.ipify.org?format=text"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let address = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  address.split(separator: ".").count == 4 else { awayNote = "Could not find this home's internet address. Check the internet connection."; return }
            let before = awayArrivals
            let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: MirrorProtocol.awayPort)!, using: .tcp)
            connection.start(queue: netQueue)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            connection.cancel()
            if awayArrivals > before {
                awayNote = "The router is passing port \(MirrorProtocol.awayPort) to this Mac. Now connect once from the phone on home Wi-Fi, then try on mobile data."
            } else {
                awayNote = "No connection arrived on port \(MirrorProtocol.awayPort). Either the forward is not set (or points at another device), or this router does not allow the test from inside the home. Try from the phone on mobile data to be sure."
            }
        }
    }
    private var awayArrivals = 0

    /// Also written to ~/Library/Logs/CoastPlayHost.log so a problem can be diagnosed without
    /// looking at the window. The pairing code is never written there.
    @Published var status = "Starting…" { didSet { Self.log(status) } }

    static func log(_ text: String) {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/CoastPlayHost.log")
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
    @Published var isError = false
    @Published var code = ""
    @Published var clientConnected = false
    @Published var clientText = "No phone connected"
    @Published var canControl = InputInjector.isTrusted
    @Published var addressText = "…"
    @Published var gameKeys = UserDefaults.standard.bool(forKey: "gameKeys") {
        didSet {
            UserDefaults.standard.set(gameKeys, forKey: "gameKeys")
            injector.setMode(gameKeys ? .gameKeys : .desktop)
            Self.log("Controller mode: \(gameKeys ? "game keys" : "mouse (desktop)").")
        }
    }

    private let capturer = ScreenCapturer()
    private let injector = InputInjector()
    private var listener: NWListener?
    private var awayListener: NWListener?
    private var awayKey = ""
    private let netQueue = DispatchQueue(label: "rgp.host.net")
    private var client: ClientLink?
    private var started = false
    private var lastAccept = Date.distantPast

    var formattedCode: String { code.count == 8 ? "\(code.prefix(4)) \(code.suffix(4))" : code }
    var controlText: String { canControl ? "Control from the phone is allowed" : "View only — control not allowed yet" }

    // The code lives in a private file (owner-only permissions). A rebuilt, ad-hoc-signed
    // prototype would lose Keychain access on every build; move this to the Keychain for release.
    private var codeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RGPMirrorHost")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("pairing-code")
    }

    private var awayKeyURL: URL { codeURL.deletingLastPathComponent().appendingPathComponent("away-key") }

    /// The long key for the away port. Kept in the same private folder as the pairing code.
    private func loadOrCreateAwayKey(fresh: Bool = false) {
        if !fresh, let saved = try? String(contentsOf: awayKeyURL, encoding: .utf8), saved.count == 64 { awayKey = saved; return }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        awayKey = bytes.map { String(format: "%02x", $0) }.joined()
        try? awayKey.write(to: awayKeyURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: awayKeyURL.path)
    }

    private func loadOrCreateCode() {
        if let saved = try? String(contentsOf: codeURL, encoding: .utf8), saved.count == 8, saved.allSatisfy(\.isNumber) {
            code = saved
        } else {
            regenerateCode(restart: false)
        }
    }

    func regenerateCode(restart: Bool = true) {
        var generator = SystemRandomNumberGenerator()
        code = String(format: "%08d", Int.random(in: 0..<100_000_000, using: &generator))
        try? code.write(to: codeURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codeURL.path)
        if restart {
            loadOrCreateAwayKey(fresh: true)     // a new code also cuts off every phone's away access
            dropClient()
            startListener()
        }
    }

    func requestControl() {
        InputInjector.promptForPermission()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                self.canControl = InputInjector.isTrusted
                if self.canControl { timer.invalidate() }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        injector.setMode(gameKeys ? .gameKeys : .desktop)
        loadOrCreateCode()
        loadOrCreateAwayKey()
        applyKeepAwake()
        findRouter()
        if let addresses = Host.current().addresses.first(where: { $0.contains(".") && !$0.hasPrefix("127.") }) {
            addressText = "\(addresses):\(MirrorProtocol.defaultPort)"
            localAddress = addresses
        }
        capturer.onVideo = { [weak self] data, isKeyframe in self?.netQueue.async { self?.client?.sendVideo(data, isKeyframe: isKeyframe) } }
        // Every 2 seconds: look at how far behind the phone is and adjust picture quality to
        // suit. Every 10 seconds: write the figures to the log.
        var ticks = 0, sumAvg = 0.0, worst = 0.0, dropped = 0, sent = 0, samples = 0
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.netQueue.async {
                guard let stats = self.client?.takeDelayStats() else { return }
                Task { @MainActor in
                    guard self.clientConnected else { ticks = 0; sumAvg = 0; worst = 0; dropped = 0; sent = 0; samples = 0; return }
                    let before = self.capturer.bitrate
                    if stats.dropped > 0 || stats.averageMs > 150 { self.capturer.setBitrate(before * 7 / 10) }
                    else if stats.sent > 30, stats.averageMs < 70, stats.worstMs < 150 { self.capturer.setBitrate(before * 23 / 20) }
                    if stats.sent > 0 { sumAvg += stats.averageMs; samples += 1 }
                    worst = max(worst, stats.worstMs); dropped += stats.dropped; sent += stats.sent
                    ticks += 1
                    if ticks >= 5 {
                        Self.log(String(format: "Picture in the last 10 s: %d sent, %d held back, delay to the phone and back about %.0f ms (worst %.0f ms), now sending at %.1f Mbps.",
                                        sent, dropped, samples > 0 ? sumAvg / Double(samples) : 0, worst, Double(self.capturer.bitrate) / 1_000_000))
                        ticks = 0; sumAvg = 0; worst = 0; dropped = 0; sent = 0; samples = 0
                    }
                }
            }
        }
        capturer.onAudio = { [weak self] data in self?.netQueue.async { self?.client?.send(.audio, data) } }
        // Every 10 seconds, note in the log whether this Mac is producing sound and passing it on.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let pic = self.capturer.takePictureStats()
                Self.log("Screen in the last 10 s: macOS delivered \(pic.delivered) frames, \(pic.new) were new pictures, \(pic.encoded) came out of the encoder (about \(pic.encoded / 10) a second).")
                let s = self.capturer.takeSoundStats()
                guard self.clientConnected || s.peakPercent > 0 || s.delivered == 0 else { return }
                Self.log("Sound in the last 10 s: \(s.delivered) buffers from macOS, \(s.forwarded) passed on, loudest level \(s.peakPercent)%" + (s.format.isEmpty ? "" : " (\(s.format))") + (s.delivered == 0 ? " — macOS is delivering no sound to this app" : s.peakPercent == 0 ? " — the Mac is silent, nothing is playing" : "") + ".")
            }
        }
        capturer.onStopped = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.status = "Screen capture stopped: \(message). Starting it again…"; self.isError = true
                // macOS stops capture when the display sleeps, the Mac locks, or sharing is ended
                // from the menu bar. Start again by itself rather than leaving the phone with nothing.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    try await self.capturer.start()
                    self.injector.displayID = self.capturer.displayID
                    self.isError = false
                    self.sharing = true
                    self.status = "Sharing this screen at \(self.capturer.width)×\(self.capturer.height). Waiting for the phone."
                    self.capturer.requestKeyframe()
                } catch {
                    self.status = "Screen capture could not restart (\(error.localizedDescription)). Quit and reopen CoastPlay Host."
                }
            }
        }
        Task {
            do {
                try await capturer.start()
                injector.displayID = capturer.displayID
                sharing = true
                status = "Sharing this screen at \(capturer.width)×\(capturer.height). Waiting for the phone."
                startListener()
            } catch {
                status = "Can't capture the screen. Allow “CoastPlay Host” under System Settings → Privacy & Security → Screen & System Audio Recording, then reopen this app. (\(error.localizedDescription))"
                isError = true
            }
        }
    }

    private func startListener() {
        listener?.cancel()
        do {
            let listener = try NWListener(using: MirrorProtocol.parameters(pairingCode: code),
                                          on: NWEndpoint.Port(rawValue: MirrorProtocol.defaultPort)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: MirrorProtocol.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor in self?.status = "Network listener failed: \(error.localizedDescription)"; self?.isError = true }
                }
            }
            listener.start(queue: netQueue)
            Self.log("Listening for the phone on port \(MirrorProtocol.defaultPort).")
            self.listener = listener
            // The away port: long key only, no announcement on the network.
            awayListener?.cancel()
            let away = try NWListener(using: MirrorProtocol.parameters(pairingCode: MirrorProtocol.awaySecret(awayKey)),
                                      on: NWEndpoint.Port(rawValue: MirrorProtocol.awayPort)!)
            away.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, away: true) }
            }
            away.start(queue: netQueue)
            Self.log("Listening for away-from-home connections on port \(MirrorProtocol.awayPort).")
            self.awayListener = away
        } catch {
            status = "Could not open the network port: \(error.localizedDescription)"
            isError = true
        }
    }

    private func accept(_ connection: NWConnection, away: Bool = false) {
        // At most one new connection per second, to slow down guessing of the pairing code.
        guard Date().timeIntervalSince(lastAccept) > 1 else { connection.cancel(); return }
        lastAccept = Date()
        dropClient()
        let hello = MirrorHello(name: Host.current().localizedName ?? "Mac", width: capturer.width, height: capturer.height,
                                fps: capturer.fps, canControl: InputInjector.isTrusted)
        let link = ClientLink(connection: connection, queue: netQueue, hello: hello, awayKey: away ? nil : awayKey)
        Self.log(away ? "Phone connecting (away-from-home port)." : "Phone connecting.")
        if away { awayArrivals += 1 }
        // Over the internet, start small and let the picture quality climb as the link proves itself.
        // Starting at the home-network rate swamped a 5G link for the first half minute (2026-11-18).
        if away { capturer.setBitrate(0) }
        link.onReady = { [weak self] in
            self?.capturer.requestKeyframe()
            Task { @MainActor in
                guard let self else { return }
                self.clientConnected = true; self.clientText = away ? "Phone connected (away from home)" : "Phone connected"
                if !self.pairedOnce { self.pairedOnce = true; UserDefaults.standard.set(true, forKey: "pairedOnce") }
                if away, !self.awayReached { self.awayReached = true; UserDefaults.standard.set(true, forKey: "awayReached") }
            }
        }
        link.onController = { [weak self] state in self?.injector.handle(controller: state) }
        link.onPointer = { [weak self] event in self?.injector.handle(pointer: event) }
        link.onText = { [weak self] text in self?.injector.handle(text: text) }
        link.onKey = { [weak self] key in self?.injector.handle(key: key) }
        link.onMode = { [weak self] on in Task { @MainActor in if self?.gameKeys != on { self?.gameKeys = on } } }
        link.onKeyframeRequest = { [weak self] in self?.capturer.requestKeyframe() }
        link.onClosed = { [weak self, weak link] in
            self?.injector.releaseAll()
            Task { @MainActor in
                guard let self, self.client === link else { return }
                self.client = nil; self.clientConnected = false; self.clientText = "No phone connected"
                Self.log("Phone disconnected.")
            }
        }
        netQueue.async { self.client = link; link.start() }
    }

    private func dropClient() {
        let old = client
        netQueue.async { old?.close() }
        injector.releaseAll()
        clientConnected = false
        clientText = "No phone connected"
    }
}

/// One connected phone. All methods run on the network queue.
final class ClientLink {
    var onReady: (() -> Void)?
    var onController: ((ControllerState) -> Void)?
    var onPointer: ((PointerEvent) -> Void)?
    var onText: ((String) -> Void)?
    var onKey: ((SpecialKey) -> Void)?
    var onMode: ((Bool) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    var onClosed: (() -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let hello: MirrorHello
    private let awayKey: String?
    private var parser = MirrorFrameParser()
    private var ready = false
    private var closed = false
    // Flow control: the phone reports how many pictures have arrived. Pictures sent but not yet
    // reported are "in flight". Too many in flight means the network is behind, so we stop
    // sending, then restart cleanly from a keyframe once it has caught up.
    private var sentFrames: UInt32 = 0, ackedFrames: UInt32 = 0
    private var sendTimes: [UInt32: Date] = [:]
    private var waitingForKeyframe = false, waitedFrames = 0
    private var resyncs = 0
    private var lastAckProgress = Date()
    private var baseDelay = 0.1          // seconds; the link's normal round trip
    private var delaySum = 0.0, delayWorst = 0.0, delayCount = 0, droppedSince = 0, sentSince = 0

    func takeDelayStats() -> (averageMs: Double, worstMs: Double, dropped: Int, sent: Int) {
        let result = (delayCount > 0 ? delaySum / Double(delayCount) : 0, delayWorst, droppedSince, sentSince)
        delaySum = 0; delayWorst = 0; delayCount = 0; droppedSince = 0; sentSince = 0
        return result
    }

    private func acknowledged(_ count: UInt32) {
        if count != ackedFrames { lastAckProgress = Date() }
        ackedFrames = count
        if let sent = sendTimes[count] {
            let seconds = Date().timeIntervalSince(sent)
            delaySum += seconds * 1000; delayCount += 1; delayWorst = max(delayWorst, seconds * 1000)
            // The quickest recent round trip is what this link costs when nothing is queued.
            // Let it creep up slowly so it follows a link that really has become slower.
            baseDelay = min(seconds, baseDelay + 0.002)
        }
        sendTimes = sendTimes.filter { $0.key > count }
    }

    init(connection: NWConnection, queue: DispatchQueue, hello: MirrorHello, awayKey: String?) {
        self.connection = connection; self.queue = queue; self.hello = hello; self.awayKey = awayKey
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.ready = true
                if let data = try? JSONEncoder().encode(self.hello) { self.send(.hello, data) }
                // On the home network only: hand the phone the long key it needs for the away port.
                if let awayKey = self.awayKey { self.send(.awayKey, Data(awayKey.utf8)) }
                self.onReady?()
                self.receive()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        onClosed?()
    }

    func close() { connection.cancel() }

    func send(_ type: MirrorProtocol.MessageType, _ payload: Data) {
        guard ready, !closed else { return }
        connection.send(content: MirrorProtocol.frame(type, payload), completion: .contentProcessed { _ in })
    }

    /// Holds pictures back instead of queueing them when the phone or network falls behind.
    /// "Behind" is judged by time, not by a fixed number of pictures: a mobile link with a long
    /// round trip always has many pictures on the way, and that alone is not a queue building up.
    func sendVideo(_ payload: Data, isKeyframe: Bool) {
        guard ready, !closed else { return }
        let now = Date()
        var inFlight = Int(Int32(bitPattern: sentFrames &- ackedFrames))
        if inFlight < 0 { sentFrames = ackedFrames; sendTimes.removeAll(); inFlight = 0 }   // counts crossed: line up
        if waitingForKeyframe {
            if inFlight > 2 {
                droppedSince += 1
                // Nothing acknowledged for three seconds: the phone has everything it will get.
                // (One second was too short: a slow mobile link can go quiet that long and recover.)
                guard now.timeIntervalSince(lastAckProgress) > 3 else { return }
                sentFrames = ackedFrames; sendTimes.removeAll(); resyncs += 1
                let n = resyncs, gap = inFlight
                Task { @MainActor in MirrorHost.log("Picture counts drifted by \(gap); lined up again (time \(n) this session).") }
            }
            // Caught up. Start again from a fresh keyframe; ask again every half second until one
            // gets through (asking only once could leave the picture frozen for good).
            if !isKeyframe {
                droppedSince += 1
                waitedFrames += 1
                if waitedFrames == 1 || waitedFrames % 30 == 0 { onKeyframeRequest?() }
                return
            }
            waitingForKeyframe = false; waitedFrames = 0
        } else if let oldest = sendTimes[ackedFrames &+ 1], now.timeIntervalSince(oldest) > min(baseDelay, 1) + 0.35 {
            // The oldest picture still on its way has been out much longer than this link
            // normally takes: a queue is building. Stop adding to it.
            waitingForKeyframe = true; droppedSince += 1
            return
        }
        if sentFrames == ackedFrames { lastAckProgress = now }
        sentFrames &+= 1; sentSince += 1
        sendTimes[sentFrames] = now
        connection.send(content: MirrorProtocol.frame(.video, payload), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for (type, payload) in self.parser.append(data) {
                    switch type {
                    case .controller: if let state = MirrorProtocol.unpackController(payload) { self.onController?(state) }
                    case .pointer: if let event = MirrorProtocol.unpackPointer(payload) { self.onPointer?(event) }
                    case .keyframeRequest: self.onKeyframeRequest?()
                    case .text: if payload.count <= 256, let text = String(data: payload, encoding: .utf8) { self.onText?(text) }
                    case .videoAck:
                        if payload.count == 4 {
                            let b = [UInt8](payload)
                            self.acknowledged(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
                        }
                    case .controllerMode: if payload.count == 1 { self.onMode?(payload[payload.startIndex] == 1) }
                    case .key: if payload.count == 1, let key = SpecialKey(rawValue: payload[payload.startIndex]) { self.onKey?(key) }
                    default: break
                    }
                }
                if self.parser.corrupt { self.connection.cancel(); return }
            }
            if isComplete || error != nil { self.connection.cancel(); self.finish(); return }
            self.receive()
        }
    }
}
