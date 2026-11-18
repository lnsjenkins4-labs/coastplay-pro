// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PRIVATE PROTOTYPE — NOT FOR DISTRIBUTION.
import Foundation
import Network
import CChiakiShim
import RGPCore
import RGPPS5

/// Real PS5 source backed by the chiaki-ng library. Implements the same `ConsoleSource`
/// contract as the mock, so the app code above it does not change.
public final class ChiakiConsoleSource: ConsoleSource, AwayPreparing {
    public let kind: ConsoleKind = .ps5
    public let isDemo = false
    public let requiresAccountIdentifier = true
    public var progressHandler: ((String) -> Void)?
    private let psnSignIn = PSNSignIn()
    public var accountSignIn: AccountSignIn? { psnSignIn }
    public var account: Data?
    public var onAccountUpdated: ((Data) -> Void)?
    public var onConsoleMoved: ((String, String) -> Void)?
    private let pathMonitor = NWPathMonitor()

    public init() {
        pathMonitor.start(queue: DispatchQueue(label: "rgp.path"))
        #if DEBUG
        rgp_set_debug_log(true)
        #endif
    }

    /// What kind of network this device is using right now.
    private var networkKind: String {
        let path = pathMonitor.currentPath
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "ethernet" }
        return path.status == .satisfied ? "other" : "offline"
    }

    /// Records a step in the on-device connection log (no secrets) and, in debug builds, the console.
    private func diag(_ text: String) {
        ConnectionLog.shared.add(text)
        #if DEBUG
        print("RGPDIAG \(text)")
        #endif
    }

    /// Asks the console what state it is in. nil = no answer (off, unreachable, or blocked).
    private func status(of host: String) async -> DiscoveredConsole.Status? {
        let found = try? await Task.detached { try PS5Discovery.search(address: host, timeout: 1.5) }.value
        return found?.first?.status
    }

    public func discover(address: String?, timeout: TimeInterval) async throws -> [DiscoveredConsole] {
        try await Task.detached {
            if let address, !address.isEmpty { return try PS5Discovery.search(address: address, timeout: timeout) }
            return try PS5Discovery.searchNetwork(timeout: timeout)
        }.value
    }

    public func register(_ request: PairingRequest) async throws -> (ConsoleDescriptor, PairingSecret) {
        guard let idText = request.accountIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              let accountID = Data(base64Encoded: idText), accountID.count == 8 else {
            throw SessionFailure(code: .pairingRejected, title: "Account ID doesn't look right",
                                 message: "The app has no usable PlayStation account for pairing.",
                                 recovery: ["Sign in with PlayStation again, then pair."], canRetry: false)
        }
        let digits = request.pin.filter(\.isNumber)
        guard digits.count == 8, let pin = UInt32(digits) else { throw SessionFailure.pairingRejected }
        let host = request.console.address

        let result: (Int32, Data, String) = await Task.detached {
            var cred = [UInt8](repeating: 0, count: Int(RGP_CRED_SIZE))
            var nick = [CChar](repeating: 0, count: Int(RGP_NICKNAME_SIZE))
            let rc = accountID.withUnsafeBytes { id in
                rgp_register(host, id.bindMemory(to: UInt8.self).baseAddress, pin, &cred, &nick, 30)
            }
            return (rc, Data(cred), String(cString: nick))
        }.value
        guard result.0 == 0 else { throw SessionFailure.pairingRejected }

        let name = result.2.isEmpty ? request.console.name : result.2
        let descriptor = ConsoleDescriptor(id: request.console.id, name: name, kind: .ps5,
                                           lastKnownAddress: host, isDemo: false)
        return (descriptor, PairingSecret(data: result.1))
    }

    static func remoteFailure(stage: Int32) -> SessionFailure {
        let reached = stage >= 5
        if reached, RemoteDiagnostics.sawPortRewriting {
            return SessionFailure(
                code: .consoleUnreachable, title: "This network can't connect directly to your console",
                message: "PlayStation Network found your console, but the network this device is on changes its connection details for every destination, so the console's replies never arrive. This is common on mobile networks.",
                recovery: ["At home, turn on UPnP in your router's settings, restart the console, and try again from this network.",
                           "Try from a Wi-Fi network instead of mobile data; most Wi-Fi networks work.",
                           "The game is unaffected; nothing is wrong with your console."])
        }
        return SessionFailure(
            code: .consoleUnreachable, title: "Couldn't connect away from home",
            message: reached
                ? "PlayStation Network found your console, but this network would not let the two connect directly."
                : "PlayStation Network could not reach your console.",
            recovery: reached
                ? ["Some mobile, hotel and office networks block direct connections. Try a different network or a hotspot.",
                   "It works more often when the console is on a network cable at home."]
                : ["Check the console is switched on, or in rest mode with “Stay Connected to the Internet” turned on.",
                   "Check Remote Play is enabled on the console.",
                   "Make sure this device has a working internet connection."])
    }

    /// Away from home: PlayStation Network introduces this device and the console, then the
    /// picture, sound and input travel directly between them. No server of ours is involved.
    private func openRemote(console: ConsoleDescriptor, config: StreamConfig, destination: DisplayDestination?) async throws -> ConsoleSession {
        guard let stored = account else { throw PSNSignIn.signInAgain }
        progressHandler?("Not on the console's network. Connecting through PlayStation Network…")
        diag("Away route: this device's network interfaces: \(RemoteDiagnostics.interfaceSummary()).")
        rgp_set_log_sink { level, message in RemoteDiagnostics.receive(level: level, message: message) }
        RemoteDiagnostics.begin()
        defer { RemoteDiagnostics.end() }
        let (psn, updated) = try await psnSignIn.refreshed(stored)
        if let updated { account = updated; onAccountUpdated?(updated) }
        guard let accountID = Data(base64Encoded: psn.accountID), accountID.count == 8 else { throw PSNSignIn.signInAgain }
        let token = psn.accessToken

        let listed: [(name: String, uid: Data, enabled: Bool)]? = await Task.detached {
            var devices = [rgp_psn_device](repeating: rgp_psn_device(), count: 8)
            var count = 0
            guard rgp_psn_list_ps5(token, &devices, 8, &count) == 0 else { return nil }
            return devices.prefix(count).map { device in
                let name = withUnsafeBytes(of: device.name) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
                let uid = withUnsafeBytes(of: device.uid) { Data($0) }
                return (name, uid, device.remote_play_enabled)
            }
        }.value
        diag("Away route: PlayStation Network console list: \(listed.map { "\($0.count) console(s)" } ?? "could not be fetched").")
        guard let listed else {
            throw SessionFailure(code: .consoleUnreachable, title: "Couldn't reach PlayStation Network",
                                 message: "The app could not get your console list from PlayStation Network.",
                                 recovery: ["Check this device's internet connection and try again.",
                                            "If it keeps failing, sign out of PlayStation in Settings and sign in again."])
        }
        // Match the saved console by name; with a single console on the account there is no doubt.
        guard let target = listed.first(where: { $0.name.caseInsensitiveCompare(console.name) == .orderedSame })
                ?? (listed.count == 1 ? listed.first : nil) else {
            throw SessionFailure(code: .consoleUnreachable, title: "Console not found on your PlayStation account",
                                 message: "PlayStation Network does not list a console named “\(console.name)” for the signed-in account.",
                                 recovery: ["Make sure the console is signed in to the same PlayStation account.",
                                            "If you renamed the console, pair it again at home."], canRetry: false)
        }
        guard target.enabled else { throw SessionFailure.remotePlayDisabled }

        progressHandler?("Found \(target.name). Opening a direct connection…")
        // First the ordinary way; if the network blocks it, once more in the mode meant for
        // networks that rewrite ports (many mobile networks and hotspots).
        // Plan: ordinary attempt; if the console did not answer PlayStation Network in time, the
        // same again after a pause (it may still be closing an earlier session); if the network
        // blocked the direct path, once more in the mode for networks that rewrite ports.
        var lastStage: Int32 = 0
        var attempts: [Bool] = [false]
        var index = 0
        var retriedStart = false
        while index < attempts.count {
            let portGuessing = attempts[index]
            index += 1
            let session = ChiakiConsoleSession(config: config.forAway, destination: destination)
            do {
                try await session.startRemote(token: token, consoleUID: target.uid, accountID: accountID, portGuessing: portGuessing)
                diag("Away route: connected\(portGuessing ? " on the second attempt (mobile-network mode)" : " on the first attempt").")
                return session
            } catch let error as RemoteStageError {
                lastStage = error.stage
                let steps: [Int32: String] = [1: "starting", 2: "creating the PlayStation Network session", 3: "preparing the offer",
                                              4: "reaching the console through PlayStation Network", 5: "opening the direct path",
                                              6: "setting up the stream", 7: "starting the stream"]
                diag("Away route: \(portGuessing ? "second attempt (mobile-network mode)" : "first attempt") failed while \(steps[error.stage] ?? "at step \(error.stage)").")
                await session.close()
                if error.stage == 4, !retriedStart {
                    retriedStart = true
                    attempts.append(portGuessing)
                    progressHandler?("The console didn't answer yet. Trying again…")
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                } else if error.stage == 5, !portGuessing {
                    attempts.append(true)
                    progressHandler?("This network blocked the first attempt. Trying another way…")
                    try await Task.sleep(nanoseconds: 5_000_000_000)   // let the console drop the first attempt
                }
            } catch {
                await session.close()
                throw error
            }
        }
        throw Self.remoteFailure(stage: lastStage)
    }

    public func openSession(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                            destination: DisplayDestination?) async throws -> ConsoleSession {
        guard var host = console.lastKnownAddress else { throw SessionFailure.consoleUnreachable }
        guard secret.data.count == Int(RGP_CRED_SIZE) else { throw SessionFailure.credentialsMissing }

        var state = await status(of: host)
        // On Wi-Fi with no answer at the saved address: the router may have given the console a
        // new address (this happens after a restart, or when it moves from Wi-Fi to a cable).
        // Look for it on this network before deciding we are away from home.
        if state == nil, networkKind == "wifi" || networkKind == "ethernet",
           let found = try? await Task.detached(operation: { try PS5Discovery.searchNetwork(timeout: 2) }).value,
           let match = found.first(where: { $0.id == console.id })
                ?? found.first(where: { $0.name.caseInsensitiveCompare(console.name) == .orderedSame }),
           match.address != host {
            diag("Console found at a new address on this network (\(RemoteDiagnostics.shorten(match.address))); remembering it.")
            host = match.address
            state = match.status
            onConsoleMoved?(console.id, match.address)
        }
        #if DEBUG
        let forceRemote = UserDefaults.standard.bool(forKey: "forceRemote")   // engineering test only
        #else
        let forceRemote = false
        #endif
        diag("Play pressed. Network: \(networkKind). Console at home address: \(state.map { $0.rawValue } ?? "no answer"). Signed in: \(account != nil ? "yes" : "no").")

        // No answer on the home address: we are probably on another network.
        if state == nil || forceRemote {
            // 1. Straight to the home's internet address, if the router forwards the console's
            //    ports. This works even on mobile networks that defeat the PlayStation Network way.
            if !forceRemote, let direct = try await openDirect(console: console, secret: secret, config: config, destination: destination) {
                return direct
            }
            // 2. Through PlayStation Network, if the person has signed in.
            if account != nil {
                return try await openRemote(console: console, config: config, destination: destination)
            }
        }

        try await wakeIfAsleep(host: host, secret: secret, state: state)
        let session = try await startSession(host: host, secret: secret, isLocal: true, config: config, destination: destination)
        Task { await self.learnHomeInternetAddress(for: console) }
        return session
    }

    /// Starts a session. A console that has only just closed a session can answer "in use" for a
    /// few seconds (seen 2026-11-16, four seconds after our own disconnect), so that one answer
    /// is retried a few times before it is reported as a real "in use".
    private func startSession(host: String, secret: PairingSecret, isLocal: Bool, config: StreamConfig,
                              destination: DisplayDestination?) async throws -> ChiakiConsoleSession {
        var attempt = 0
        while true {
            let session = ChiakiConsoleSession(config: config, destination: destination)
            do {
                try await session.start(host: host, secret: secret, isLocal: isLocal)
                return session
            } catch let failure as SessionFailure where failure.code == .consoleBusy && attempt < 3 {
                attempt += 1
                diag("Console answered \"in use\". It may still be closing the last session; waiting 4 seconds (try \(attempt) of 3).")
                progressHandler?("The console is still closing the last session. Trying again…")
                try await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    /// Rest mode: the console says so itself, so ask it to wake and wait for it to report ready.
    private func wakeIfAsleep(host: String, secret: PairingSecret, state: DiscoveredConsole.Status?) async throws {
        guard state == .standby else { return }
        progressHandler?("The console is in rest mode. Waking it…")
        diag("Console reports rest mode; sending wake request.")
        let sent = secret.data.withUnsafeBytes { rgp_wake(host, $0.bindMemory(to: UInt8.self).baseAddress) }
        var awake = false
        if sent == 0 {
            for _ in 0..<20 {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if await status(of: host) == .ready { awake = true; break }
            }
        }
        diag(awake ? "Console woke up." : "Console did not wake within 40 seconds.")
        guard awake else { throw SessionFailure.consoleAsleep }
        progressHandler?("Console is awake. Connecting…")
        try await Task.sleep(nanoseconds: 3_000_000_000)   // give Remote Play a moment to start
    }

    // MARK: Direct route to the home's internet address (needs router port forwarding)

    private func homeAddressKey(_ console: ConsoleDescriptor) -> String { "homeInternetAddress.\(console.id)" }

    /// While on the home network, remember the home's public internet address so the app can
    /// try it directly when away. Uses one request to a public "what is my address" service
    /// (api.ipify.org); nothing about the person or console is sent.
    private func learnHomeInternetAddress(for console: ConsoleDescriptor) async {
        guard networkKind == "wifi" || networkKind == "ethernet",
              let url = URL(string: "https://api.ipify.org?format=text"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.split(separator: ".").count == 4, text.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        if UserDefaults.standard.string(forKey: homeAddressKey(console)) != text {
            UserDefaults.standard.set(text, forKey: homeAddressKey(console))
            diag("Home internet address noted for away-from-home use (\(RemoteDiagnostics.shorten(text))).")
        }
    }

    /// At home (the console answers on its home address over Wi-Fi), note the home's internet
    /// address for each saved console so the direct away route is ready without playing first.
    public func prepareForAway(consoles: [ConsoleDescriptor]) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)      // let the network path settle after launch
        let network = networkKind
        guard network == "wifi" || network == "ethernet" else { return }
        for console in consoles where console.kind == .ps5 && !console.isDemo {
            guard UserDefaults.standard.string(forKey: homeAddressKey(console)) == nil else { continue }
            guard let host = console.lastKnownAddress, NetworkAddress.isLocal(host) else { continue }
            guard await status(of: host) != nil else {
                diag("Getting ready for away play: \(console.name) did not answer at home just now.")
                continue
            }
            await learnHomeInternetAddress(for: console)
            if UserDefaults.standard.string(forKey: homeAddressKey(console)) == nil {
                diag("Getting ready for away play: could not look up the home internet address.")
            }
        }
    }

    /// Returns nil when this route is not available, so the caller can try the next one.
    private func openDirect(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                            destination: DisplayDestination?) async throws -> ConsoleSession? {
        guard let publicHost = UserDefaults.standard.string(forKey: homeAddressKey(console)) else {
            diag("Direct route: no home internet address known yet (play once at home first).")
            return nil
        }
        progressHandler?("Not on the console's network. Trying your home's internet address…")
        let state = await status(of: publicHost)
        guard let state else {
            diag("Direct route: the home internet address did not answer. The router is not forwarding the console's ports, or the address has changed.")
            return nil
        }
        diag("Direct route: console answered at the home internet address (\(state.rawValue)).")
        do {
            try await wakeIfAsleep(host: publicHost, secret: secret, state: state)
            let session = try await startSession(host: publicHost, secret: secret, isLocal: false, config: config.forAway, destination: destination)
            diag("Direct route: connected.")
            return session
        } catch let failure as SessionFailure where failure.code == .consoleBusy {
            // The console is reachable and really is in use. Another route would not change
            // that, so say so instead of trying PlayStation Network.
            diag("Direct route: the console is in use.")
            throw failure
        } catch {
            diag("Direct route: failed to start a session (\((error as? SessionFailure)?.title ?? "error")).")
            return nil
        }
    }
}

/// Copies the library's own explanation of the away-from-home steps into the connection log.
/// Only lines about finding a path between the two ends are kept; anything mentioning keys,
/// tokens, accounts or pairing is dropped, and network addresses are shortened.
enum RemoteDiagnostics {
    private static let lock = NSLock()
    private static var remaining = 0

    /// Set when the library finds that this device's network hands out a different, unpredictable
    /// port for every destination, which is what defeats a direct connection.
    private(set) static var sawPortRewriting = false

    static func begin() { lock.lock(); remaining = 40; sawPortRewriting = false; lock.unlock() }
    static func end() { lock.lock(); remaining = 0; lock.unlock() }

    private static let allow = ["check_candidates", "create_offer", "get_client_addr", "STUN", "stun", "NAT", "IPv6", "IPV6",
                                "ipv6", "UPnP", "upnp", "punch", "candidate", "timed out", "unreachable"]
    private static let deny = ["token", "Token", "key", "Key", "ccount", "duid", "Duid", "payload", "egist", "Bearer",
                               "uthoriz", "Request ID", "offset", "session id", "Session ID"]

    static func receive(level: CChar, message: UnsafePointer<CChar>?) {
        guard let message else { return }
        lock.lock()
        let active = remaining > 0
        lock.unlock()
        guard active else { return }
        let text = String(cString: message)
        if text.contains("Port rewriting NAT detected") { lock.lock(); sawPortRewriting = true; lock.unlock() }
        guard allow.contains(where: text.contains), !deny.contains(where: text.contains),
              !text.contains("Resending requests") else { return }     // 20 identical lines per attempt
        lock.lock(); remaining -= 1; lock.unlock()
        ConnectionLog.shared.add("   detail: \(shorten(text))")
    }

    /// 203.0.113.57 -> 203.0.x.x, and long IPv6 addresses -> first group only.
    static func shorten(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b"#, with: "$1.$2.x.x", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\b([0-9a-fA-F]{1,4}):[0-9a-fA-F:]{6,}\b"#, with: "$1:…(IPv6)", options: .regularExpression)
        return String(out.prefix(220))
    }

    /// Which address families each network interface has right now (no addresses recorded).
    static func interfaceSummary() -> String {
        var seen: [String: Set<String>] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "unknown" }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard Int32(entry.pointee.ifa_flags) & IFF_UP != 0, let addr = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("pdp_ip") || name.hasPrefix("en") else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET: seen[name, default: []].insert("IPv4")
            case AF_INET6:
                let bytes = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr.__u6_addr.__u6_addr8 }
                seen[name, default: []].insert(bytes.0 == 0xfe && bytes.1 & 0xc0 == 0x80 ? "IPv6-link-local" : "IPv6")
            default: break
            }
        }
        return seen.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.sorted().joined(separator: "+"))" }.joined(separator: ", ")
    }
}

/// Which step of the away-from-home connection failed (see the shim header).
struct RemoteStageError: Error { let stage: Int32 }

/// One live session. Library callbacks arrive on its own threads; everything they touch here is
/// either lock-protected or a thread-safe sink.
final class ChiakiConsoleSession: ConsoleSession {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let config: StreamConfig
    private let destination: DisplayDestination?

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var connected = false
    private var closed = false
    private var lastRoundTripMs: Double?
    private(set) var isLocalRoute = true

    // Measured by counting what actually arrives.
    private var windowStart = Date()
    private var windowFrames = 0, windowBytes = 0, windowLost = 0
    private var frameCounter: Int64 = 0

    init(config: StreamConfig, destination: DisplayDestination?) {
        self.config = config
        self.destination = destination
        rgp_set_bitrate_kbps(Int32(config.requestedBitrateKbps ?? 0))   // 0 = engine's own value
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    private func makeCallbacks() -> rgp_callbacks {
        rgp_callbacks(
            user: Unmanaged.passUnretained(self).toOpaque(),
            on_event: { user, type, code, _ in
                Unmanaged<ChiakiConsoleSession>.fromOpaque(user!).takeUnretainedValue().handleEvent(type: type, code: code)
            },
            on_video: { user, data, size, lost in
                Unmanaged<ChiakiConsoleSession>.fromOpaque(user!).takeUnretainedValue().handleVideo(data!, size, Int(lost))
            },
            on_audio: { user, samples, frames, channels, rate in
                Unmanaged<ChiakiConsoleSession>.fromOpaque(user!).takeUnretainedValue()
                    .handleAudio(samples!, Int(frames), Int(channels), Int(rate))
            })
    }

    private var connectedAt = Date()
    private var stallReported = false

    /// The library can stay silent for a long time when the network under it disappears (for
    /// example the phone moving from Wi-Fi to mobile data). If no picture arrives for a few
    /// seconds, say so and let the session controller reconnect, instead of a frozen picture.
    private func startStallWatch() {
        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let self else { return }
                self.lock.lock()
                let done = self.closed || self.stallReported
                let last = self.monLastFrame ?? self.connectedAt
                let stalled = Date().timeIntervalSince(last) > 5
                if stalled && !done { self.stallReported = true }
                self.lock.unlock()
                if done { return }
                if stalled {
                    ConnectionLog.shared.add("No picture for 5 seconds. Reconnecting.")
                    self.continuation.yield(.interrupted(reason: "No picture has arrived for a few seconds"))
                    return
                }
            }
        }
    }

    /// Measures network round-trip time to the console every few seconds while the session runs.
    private func startRoundTripMeasurements(host: String) {
        Thread.detachNewThread { [weak self] in
            var logged = false
            while true {
                guard let self else { return }
                self.lock.lock(); let done = self.closed; self.lock.unlock()
                if done { return }
                // A plain ping. (The console's discovery reply is not usable as a stopwatch: the
                // console takes about 100 ms to answer it even on a fast local network.)
                var value = NetworkProbe.typicalPingMs(host: host)
                // Some routers ignore pings from the internet. Fall back to
                // timing a connection to the console's Remote Play port.
                // (Seen 2026-11-16: the AT&T gateway does not answer pings from outside, so away sessions
                // rely on this fallback for every reading.)
                if value == nil { value = NetworkProbe.tcpConnectMs(host: host, port: 9295) }
                self.lock.lock()
                if value != nil || self.lastRoundTripMs == nil { self.lastRoundTripMs = value }
                if let value { self.monPings.append(value) } else { self.monPingMisses += 1 }
                self.lock.unlock()
                if let value, !logged {
                    logged = true
                    ConnectionLog.shared.add("Network round-trip: \(Int(value)) ms (network only, not button-to-screen delay).")
                }
                Thread.sleep(forTimeInterval: 4)
            }
        }
    }

    func start(host: String, secret: PairingSecret, isLocal: Bool) async throws {
        isLocalRoute = isLocal
        try? destination?.prepare(format: VideoFormat(codec: .h264, width: config.width, height: config.height))
        let callbacks = makeCallbacks()
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            lock.lock(); connectWaiter = waiter; lock.unlock()
            let opened: OpaquePointer? = secret.data.withUnsafeBytes { cred in
                rgp_session_open(host, cred.bindMemory(to: UInt8.self).baseAddress, Int32(config.height), Int32(config.fps), callbacks)
            }
            lock.lock()
            handle = opened
            lock.unlock()
            if opened == nil { resolveConnect(.failure(SessionFailure.consoleUnreachable)) }
        }
        startRoundTripMeasurements(host: host)
    }

    /// Opens the session across the internet. The introduction through PlayStation Network can
    /// take up to about a minute, so it runs off the caller's thread.
    func startRemote(token: String, consoleUID: Data, accountID: Data, portGuessing: Bool) async throws {
        isLocalRoute = false
        try? destination?.prepare(format: VideoFormat(codec: .h264, width: config.width, height: config.height))
        let callbacks = makeCallbacks()
        let height = Int32(config.height), fps = Int32(config.fps)
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            lock.lock(); connectWaiter = waiter; lock.unlock()
            Thread.detachNewThread { [self] in
                var stage: Int32 = 0
                let opened: OpaquePointer? = consoleUID.withUnsafeBytes { uid in
                    accountID.withUnsafeBytes { id in
                        rgp_session_open_remote(token, uid.bindMemory(to: UInt8.self).baseAddress,
                                                id.bindMemory(to: UInt8.self).baseAddress, height, fps, callbacks, &stage, portGuessing)
                    }
                }
                lock.lock()
                let alreadyClosed = closed
                if !alreadyClosed { handle = opened }
                lock.unlock()
                if let opened, alreadyClosed { rgp_session_close(opened) }
                #if DEBUG
                print("RGPDIAG remote open returned \(opened == nil ? "nil" : "session") stage=\(stage)")
                #endif
                if opened == nil { resolveConnect(.failure(RemoteStageError(stage: stage))) }
            }
        }
    }

    private func resolveConnect(_ result: Result<Void, Error>) {
        lock.lock()
        let waiter = connectWaiter
        connectWaiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func handleEvent(type: Int32, code: Int32) {
        switch type {
        case Int32(RGP_EVENT_CONNECTED.rawValue):
            lock.lock(); connected = true; windowStart = Date(); connectedAt = Date(); lock.unlock()
            startStallWatch()
            resolveConnect(.success(()))
        case Int32(RGP_EVENT_LOGIN_PIN_NEEDED.rawValue):
            let failure = SessionFailure(code: .unknown, title: "Console passcode needed",
                                         message: "This console profile is protected by a login passcode, which this prototype cannot enter yet.",
                                         recovery: ["Remove the login passcode for the profile, or sign in on the console first."], canRetry: false)
            finish(failure)
        case Int32(RGP_EVENT_QUIT.rawValue):
            finish(Self.failure(for: code))
        default: break
        }
    }

    /// Before "connected": fails the open. After: reports interruption or a clean end.
    private func finish(_ failure: SessionFailure?) {
        lock.lock()
        let wasConnected = connected
        let wasClosed = closed
        lock.unlock()
        if !wasConnected {
            resolveConnect(.failure(failure ?? SessionFailure.timedOut))
            return
        }
        guard !wasClosed else { return }
        if let failure, failure.code == .connectionLost {
            continuation.yield(.interrupted(reason: "The stream from the console stopped"))
        } else {
            continuation.yield(.ended(failure))
        }
    }

    private static func failure(for code: Int32) -> SessionFailure? {
        switch code {
        case Int32(RGP_QUIT_STOPPED.rawValue): return nil
        case Int32(RGP_QUIT_REFUSED.rawValue):
            return SessionFailure(code: .remotePlayDisabled, title: "The console refused the connection",
                                  message: "The console answered but would not start a session. The usual cause is that Remote Play is not enabled for the profile.",
                                  recovery: ["On the console open Settings → System → Remote Play and turn on Enable Remote Play.",
                                             "Make sure the profile signed in on the console is the one you paired with.",
                                             "If the pairing is old, forget the console and pair again."])
        case Int32(RGP_QUIT_IN_USE.rawValue): return .consoleBusy
        case Int32(RGP_QUIT_UNREACHABLE.rawValue): return .consoleUnreachable
        case Int32(RGP_QUIT_DISCONNECTED.rawValue): return .connectionLost
        case Int32(RGP_QUIT_VERSION.rawValue):
            return SessionFailure(code: .unknown, title: "Console software not supported",
                                  message: "The console reported a Remote Play version this build does not speak.",
                                  recovery: ["Update the console's system software."], canRetry: false)
        default: return .timedOut
        }
    }

    // Play monitor: one plain-language line in the connection log every 10 seconds, so a bad
    // stretch can be matched to its cause afterwards. Counts only; no keys, addresses or content.
    private var monStart = Date()
    private var monLastFrame: Date?
    private var monFrames = 0, monBytes = 0, monLost = 0, monStalls = 0
    private var monWorstGapMs = 0.0
    private var monPings: [Double] = []
    private var monPingMisses = 0
    // Network-unstable flag: one verdict per second, unstable when 3 of the last 10 were bad.
    private var secondWorstGapMs = 0.0
    private var badSeconds: [Bool] = []
    private var unstableLogged = false
    private var unstableLine: String?

    /// Call with the lock held. Returns a log line when a 10-second window has finished.
    private func monitorFrame(size: Int, lost: Int) -> String? {
        let now = Date()
        if let last = monLastFrame {
            let gap = now.timeIntervalSince(last) * 1000
            if gap > monWorstGapMs { monWorstGapMs = gap }
            if gap > secondWorstGapMs { secondWorstGapMs = gap }
            if gap > 100 { monStalls += 1 }
        }
        monLastFrame = now
        monFrames += 1; monBytes += size; monLost += max(0, lost)
        let elapsed = now.timeIntervalSince(monStart)
        guard elapsed >= 10 else { return nil }
        let fps = Double(monFrames) / elapsed
        let mbps = Double(monBytes) * 8 / elapsed / 1_000_000
        var ping = "round-trip no reading"
        if let lo = monPings.min(), let hi = monPings.max() {
            ping = "round-trip \(Int(lo))–\(Int(hi)) ms"
            if monPingMisses > 0 { ping += " (\(monPingMisses) unanswered)" }
        }
        let line = String(format: "Monitor: %.0f pictures/s, %.1f Mbps, %d lost, %d freezes over 0.1 s, longest gap %.0f ms, ",
                          fps, mbps, monLost, monStalls, monWorstGapMs) + ping + "."
        monStart = now; monFrames = 0; monBytes = 0; monLost = 0; monStalls = 0; monWorstGapMs = 0
        monPings = []; monPingMisses = 0
        return line
    }

    private func handleVideo(_ data: UnsafePointer<UInt8>, _ size: Int, _ lost: Int) {
        lock.lock()
        let monitorLine = monitorFrame(size: size, lost: lost)
        frameCounter += 1
        let pts = frameCounter * 1_000_000 / Int64(max(1, config.fps))
        windowFrames += 1; windowBytes += size; windowLost += max(0, lost)
        var report: StreamStats?
        let elapsed = Date().timeIntervalSince(windowStart)
        if elapsed >= 1 {
            let total = windowFrames + windowLost
            // Skip the first seconds of a session, which are always uneven.
            if Date().timeIntervalSince(connectedAt) > 4 {
                badSeconds.append(windowLost > 3 || secondWorstGapMs > 250 || (lastRoundTripMs ?? 0) > 300)
                if badSeconds.count > 10 { badSeconds.removeFirst() }
            }
            secondWorstGapMs = 0
            let unstable = badSeconds.filter { $0 }.count >= 3
            if unstable && !unstableLogged {
                unstableLogged = true
                unstableLine = "This network looks unstable: pictures are being lost or arriving late."
            }
            report = StreamStats(width: config.width, height: config.height,
                                 framesPerSecond: Double(windowFrames) / elapsed,
                                 bitrateKbps: Double(windowBytes) * 8 / elapsed / 1000,
                                 packetLossPercent: nil,     // the library does not report packet loss here
                                 roundTripMs: lastRoundTripMs,   // measured with a small request to the console
                                 isSimulated: false)
            report?.isUnstable = unstable
            _ = total
            windowStart = Date(); windowFrames = 0; windowBytes = 0; windowLost = 0
        }
        let unstableNote = unstableLine; unstableLine = nil
        lock.unlock()
        if let unstableNote { ConnectionLog.shared.add(unstableNote) }
        // Settings → "Record play quality". Off unless the person turned it on.
        if let monitorLine, UserDefaults.standard.bool(forKey: "recordPlayQuality") {
            ConnectionLog.shared.add(monitorLine)
        }
        destination?.enqueue(video: EncodedVideoFrame(data: Data(bytes: data, count: size), isKeyframe: false, presentationTimeUs: pts))
        if let report { continuation.yield(.stats(report)) }
    }

    private func handleAudio(_ samples: UnsafePointer<Int16>, _ frames: Int, _ channels: Int, _ rate: Int) {
        let data = Data(bytes: samples, count: frames * channels * MemoryLayout<Int16>.size)
        destination?.enqueue(audio: AudioFrame(data: data, encoding: .pcmS16(channels: channels, sampleRate: rate), presentationTimeUs: 0))
    }

    func send(_ input: ControllerState) {
        lock.lock(); let h = handle; let live = connected && !closed; lock.unlock()
        guard live, let h else { return }
        var buttons: UInt32 = 0
        let map: [(ControllerButtons, Int)] = [
            (.cross, RGP_BTN_CROSS), (.circle, RGP_BTN_CIRCLE), (.square, RGP_BTN_SQUARE), (.triangle, RGP_BTN_TRIANGLE),
            (.dpadLeft, RGP_BTN_LEFT), (.dpadRight, RGP_BTN_RIGHT), (.dpadUp, RGP_BTN_UP), (.dpadDown, RGP_BTN_DOWN),
            (.l1, RGP_BTN_L1), (.r1, RGP_BTN_R1), (.l3, RGP_BTN_L3), (.r3, RGP_BTN_R3),
            (.options, RGP_BTN_OPTIONS), (.create, RGP_BTN_CREATE), (.touchpadClick, RGP_BTN_TOUCHPAD), (.ps, RGP_BTN_PS),
        ]
        for (button, bit) in map where input.buttons.contains(button) { buttons |= UInt32(bit) }
        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trigger(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }
        // Console convention: stick Y grows downward; ours grows upward.
        rgp_session_set_controller(h, buttons, trigger(input.l2), trigger(input.r2),
                                   axis(input.leftX), axis(-input.leftY), axis(input.rightX), axis(-input.rightY))
    }

    func close() async {
        lock.lock()
        let h = handle
        handle = nil
        closed = true
        lock.unlock()
        resolveConnect(.failure(SessionFailure.timedOut))
        if let h {
            // Joins the library threads; do it off the caller's thread.
            await Task.detached { rgp_session_close(h) }.value
        }
        continuation.finish()
    }
}
