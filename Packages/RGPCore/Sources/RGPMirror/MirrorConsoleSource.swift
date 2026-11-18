import Foundation
import Network
import RGPCore

/// Phone-side source for a computer running the CoastPlay Host app.
public final class MirrorConsoleSource: ConsoleSource {
    public let kind: ConsoleKind = .computer
    public let isDemo = false
    public init() {}

    public var setupSteps: [String] {
        ["On the computer, open the CoastPlay Host app. Its window has a short setup list: follow steps 1 and 2 there.",
         "Put this device on the same Wi-Fi as the computer.",
         "Type the 8-digit code from step 3 of that window here.",
         "To have it ready whenever you want it, switch on both options under step 4 on the computer.",
         "To play away from home, do step 5 on the computer once. It sets up your router and can hand the steps to an AI helper."]
    }
    public var pairingHint: String { "Enter the 8-digit code shown in the CoastPlay Host window on the computer." }

    public func discover(address: String?, timeout: TimeInterval) async throws -> [DiscoveredConsole] {
        if let address, !address.isEmpty {
            // A typed address cannot be checked without the pairing code; pairing will verify it.
            return [DiscoveredConsole(id: "computer-\(address)", name: address, kind: .computer, address: address, status: .unknown)]
        }
        return await withCheckedContinuation { continuation in
            let browser = NWBrowser(for: .bonjour(type: MirrorProtocol.serviceType, domain: nil), using: .tcp)
            let queue = DispatchQueue(label: "rgp.mirror.browse")
            var names = Set<String>()
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint { names.insert(name) }
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                continuation.resume(returning: names.sorted().map {
                    DiscoveredConsole(id: "computer-\($0)", name: $0, kind: .computer, address: "bonjour:\($0)", status: .ready)
                })
            }
        }
    }

    public func register(_ request: PairingRequest) async throws -> (ConsoleDescriptor, PairingSecret) {
        let code = request.pin.filter(\.isNumber)
        guard code.count == 8 else { throw SessionFailure.pairingRejected }
        let secret = PairingSecret(data: Data(code.utf8))
        // Prove the code by completing a handshake and receiving the host's greeting.
        let session = MirrorSession(config: StreamConfig(), destination: nil)
        do {
            let hello = try await session.start(address: request.console.address, secret: secret)
            await session.close()
            let descriptor = ConsoleDescriptor(id: request.console.id, name: hello.name, kind: .computer,
                                               lastKnownAddress: request.console.address, isDemo: false)
            return (descriptor, secret)
        } catch {
            await session.close()
            throw SessionFailure(code: .pairingRejected, title: "Couldn't pair with the computer",
                                 message: "The computer did not accept the code, or it could not be reached.",
                                 recovery: ["Check the 8-digit code in the CoastPlay Host window and type it again.",
                                            "Make sure the host app is running and both devices are on the same network."], canRetry: false)
        }
    }

    public func openSession(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                            destination: DisplayDestination?) async throws -> ConsoleSession {
        guard let address = console.lastKnownAddress else { throw SessionFailure.consoleUnreachable }
        let session = MirrorSession(config: config, destination: destination)
        let id = console.id
        session.onAwayKey = { key in
            MirrorAwayStore.save(key: key, for: id)
            Task { await MirrorAwayStore.learnHomeAddress(for: id) }
        }
        let onHomeNetwork = await MirrorAwayStore.onWiFiOrWired()
        do {
            // On mobile data the home addresses cannot answer, so don't spend time on them.
            guard onHomeNetwork else { throw SessionFailure.timedOut }
            _ = try await session.start(address: address, secret: secret, timeout: 5)
        } catch {
            await session.close()
            // Away from home: the home's internet address on the away port, with the long key
            // the host handed over during an earlier home session.
            if !onHomeNetwork, let home = MirrorAwayStore.homeAddress(for: id), let key = MirrorAwayStore.key(for: id) {
                progressHandler?("Reaching your computer over the internet…")
                let away = MirrorSession(config: config, destination: destination)
                away.isLocalRoute = false
                let awaySecret = PairingSecret(data: Data(MirrorProtocol.awaySecret(key).utf8))
                if (try? await away.start(address: "\(home):\(MirrorProtocol.awayPort)", secret: awaySecret, timeout: 10)) != nil { return away }
                await away.close()
                throw SessionFailure(code: .consoleUnreachable, title: "Can't reach the computer from here",
                                     message: "Your home's internet address did not answer on the away port.",
                                     recovery: ["Check the computer is awake with CoastPlay Host open.",
                                                "Check the router forwards TCP port \(MirrorProtocol.awayPort) to the computer.",
                                                "Your home's internet address may have changed: connect once on home Wi-Fi to refresh it."])
            }
            if !onHomeNetwork {
                throw SessionFailure(code: .consoleUnreachable, title: "Away play isn't ready for this computer",
                                     message: "Connect to it once on home Wi-Fi first. That hands this phone the key it needs for away play.",
                                     recovery: ["Join home Wi-Fi and connect to the computer once.",
                                                "Then set the router to forward TCP port \(MirrorProtocol.awayPort) to the computer."], canRetry: false)
            }
            // The saved address can go stale: a computer's network address changes from time to
            // time. Look for the host by name on this network and try whatever answers. The
            // pairing code still has to match, so this cannot connect to someone else's computer.
            let found = (try? await discover(address: nil, timeout: 2)) ?? []
            for candidate in found where candidate.address != address {
                let retry = MirrorSession(config: config, destination: destination)
                retry.onAwayKey = session.onAwayKey
                if (try? await retry.start(address: candidate.address, secret: secret)) != nil { return retry }
                await retry.close()
            }
            // On Wi-Fi but not at home (a friend's house, a hotel): try the away route too.
            if let home = MirrorAwayStore.homeAddress(for: id), let key = MirrorAwayStore.key(for: id) {
                progressHandler?("Reaching your computer over the internet…")
                let away = MirrorSession(config: config, destination: destination)
                away.isLocalRoute = false
                let awaySecret = PairingSecret(data: Data(MirrorProtocol.awaySecret(key).utf8))
                if (try? await away.start(address: "\(home):\(MirrorProtocol.awayPort)", secret: awaySecret, timeout: 10)) != nil { return away }
                await away.close()
            }
            throw SessionFailure(code: .consoleUnreachable, title: "Can't reach the computer",
                                 message: "The CoastPlay Host app did not answer, or it no longer accepts this pairing code.",
                                 recovery: ["Check the host app is running on the computer.",
                                            "If the code in the host window changed, forget this computer and pair again.",
                                            "Make sure both devices are on the same network."])
        }
        return session
    }
}

final class MirrorSession: ConsoleSession {
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private let config: StreamConfig
    private let destination: DisplayDestination?
    private let queue = DispatchQueue(label: "rgp.mirror.session")

    // Touched only on `queue`.
    private var connection: NWConnection?
    private var parser = MirrorFrameParser()
    private var hello: MirrorHello?
    private var waiter: CheckedContinuation<MirrorHello, Error>?
    private var closed = false
    var onAwayKey: ((String) -> Void)?
    var isLocalRoute = true
    private var windowStart = Date()
    private var windowFrames = 0, windowBytes = 0
    private var frameCounter: Int64 = 0

    init(config: StreamConfig, destination: DisplayDestination?) {
        self.config = config
        self.destination = destination
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    private static func endpoint(for address: String) -> NWEndpoint {
        if address.hasPrefix("bonjour:") {
            return .service(name: String(address.dropFirst("bonjour:".count)), type: MirrorProtocol.serviceType, domain: "local.", interface: nil)
        }
        let parts = address.split(separator: ":")
        let port = parts.count == 2 ? UInt16(parts[1]) ?? MirrorProtocol.defaultPort : MirrorProtocol.defaultPort
        return .hostPort(host: NWEndpoint.Host(String(parts.first ?? "")), port: NWEndpoint.Port(rawValue: port)!)
    }

    func start(address: String, secret: PairingSecret, timeout: TimeInterval = 8) async throws -> MirrorHello {
        let code = String(decoding: secret.data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MirrorHello, Error>) in
            queue.async {
                self.waiter = cont
                let connection = NWConnection(to: Self.endpoint(for: address), using: MirrorProtocol.parameters(pairingCode: code))
                self.connection = connection
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.receive()
                    case .waiting(let error):
                        // On the home network "waiting" means refused, so stop. Over the internet it
                        // is often a brief pause while the mobile connection sorts itself out, so
                        // keep trying until the time limit and note what the system reported.
                        if timeout > 8 { ConnectionLog.shared.add("Away route is waiting: \(error.localizedDescription).") } else { self.failStart() }
                    case .failed(let error):
                        if timeout > 8 { ConnectionLog.shared.add("Away route failed: \(error.localizedDescription).") }
                        self.connectionEnded()
                    case .cancelled: self.connectionEnded()
                    default: break
                    }
                }
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.failStart() }
            }
        }
    }

    private func failStart() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(throwing: SessionFailure.timedOut)
        connection?.cancel()
    }

    private func connectionEnded() {
        if waiter != nil { failStart(); return }
        guard !closed, hello != nil else { return }
        closed = true
        continuation.yield(.interrupted(reason: "The connection to the computer stopped"))
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for (type, payload) in self.parser.append(data) { self.handle(type, payload) }
                if self.parser.corrupt { self.connection?.cancel(); return }
            }
            if isComplete || error != nil { self.connectionEnded(); return }
            self.receive()
        }
    }

    private func handle(_ type: MirrorProtocol.MessageType, _ payload: Data) {
        switch type {
        case .hello:
            guard let value = try? JSONDecoder().decode(MirrorHello.self, from: payload) else { return }
            hello = value
            windowStart = Date()
            try? destination?.prepare(format: VideoFormat(codec: .h264, width: value.width, height: value.height))
            if let waiter { self.waiter = nil; waiter.resume(returning: value) }
        case .video:
            frameCounter += 1
            // Tell the computer how far we have got, so it can hold back instead of piling up
            // pictures when the network is slow (the pile-up is what makes the picture lag).
            var count = UInt32(truncatingIfNeeded: frameCounter).bigEndian
            if let connection { connection.send(content: MirrorProtocol.frame(.videoAck, Data(bytes: &count, count: 4)), completion: .contentProcessed { _ in }) }
            windowFrames += 1; windowBytes += payload.count
            destination?.enqueue(video: EncodedVideoFrame(data: payload, isKeyframe: false,
                                                          presentationTimeUs: frameCounter * 1_000_000 / Int64(max(1, hello?.fps ?? 60))))
            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= 1 {
                continuation.yield(.stats(StreamStats(width: hello?.width, height: hello?.height,
                                                      framesPerSecond: Double(windowFrames) / elapsed,
                                                      bitrateKbps: Double(windowBytes) * 8 / elapsed / 1000,
                                                      packetLossPercent: nil, roundTripMs: nil, isSimulated: false)))
                windowStart = Date(); windowFrames = 0; windowBytes = 0
            }
        case .audio:
            destination?.enqueue(audio: AudioFrame(data: payload, encoding: .pcmS16(channels: 2, sampleRate: 48_000), presentationTimeUs: 0))
        case .awayKey:
            if payload.count == 64, let key = String(data: payload, encoding: .utf8) { onAwayKey?(key) }
        case .controller, .pointer, .keyframeRequest, .text, .key, .controllerMode, .videoAck:
            break   // client-to-host messages; ignore if a host ever sends them
        }
    }

    private func sendFrame(_ type: MirrorProtocol.MessageType, _ payload: Data) {
        queue.async {
            guard !self.closed, self.hello != nil, let connection = self.connection else { return }
            connection.send(content: MirrorProtocol.frame(type, payload), completion: .contentProcessed { _ in })
        }
    }

    func send(_ input: ControllerState) { sendFrame(.controller, MirrorProtocol.pack(input)) }
    func send(pointer: PointerEvent) { sendFrame(.pointer, MirrorProtocol.pack(pointer)) }
    func send(text: String) { sendFrame(.text, Data(text.utf8.prefix(256))) }
    func send(key: SpecialKey) { sendFrame(.key, Data([key.rawValue])) }
    func setGameKeys(_ on: Bool) { sendFrame(.controllerMode, Data([on ? 1 : 0])) }

    func close() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                self.closed = true
                if let waiter = self.waiter { self.waiter = nil; waiter.resume(throwing: SessionFailure.timedOut) }
                self.connection?.cancel()
                self.connection = nil
                self.continuation.finish()
                done.resume()
            }
        }
    }
}
