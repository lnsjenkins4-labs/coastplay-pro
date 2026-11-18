import Foundation
import RGPCore

/// DEMO ONLY. Simulates a console so the interface and failure states can be exercised
/// without hardware. Nothing here talks to a network, and nothing it produces is evidence
/// that real console streaming works.
public enum MockScenario: String, CaseIterable, Identifiable, Sendable {
    case healthy, weakNetwork, dropThenRecover, dropNoRecover, consoleAsleep, remotePlayDisabled, pairingRejected

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .healthy: return "Healthy session"
        case .weakNetwork: return "Weak network"
        case .dropThenRecover: return "Drop, then recover"
        case .dropNoRecover: return "Drop, no recovery"
        case .consoleAsleep: return "Console won't wake"
        case .remotePlayDisabled: return "Remote Play disabled"
        case .pairingRejected: return "Pairing rejected"
        }
    }
    public var detail: String {
        switch self {
        case .healthy: return "Connects and stays connected."
        case .weakNetwork: return "Connects with simulated packet loss and low bitrate."
        case .dropThenRecover: return "Interrupts after a few seconds, then reconnects."
        case .dropNoRecover: return "Interrupts, and every reconnect attempt fails."
        case .consoleAsleep: return "Connection fails: console in rest mode."
        case .remotePlayDisabled: return "Connection fails: Remote Play turned off."
        case .pairingRejected: return "Pairing fails with a rejected PIN."
        }
    }
}

public final class MockConsoleSource: ConsoleSource {
    public let kind: ConsoleKind = .ps5
    public let isDemo = true
    public var scenario: MockScenario
    /// Multiplies every simulated delay. Tests use a tiny value.
    public let timeScale: Double
    public private(set) var openCount = 0
    public private(set) var lastSession: MockConsoleSession?

    public static let demoConsoleID = "demo-console"

    public init(scenario: MockScenario = .healthy, timeScale: Double = 1) {
        self.scenario = scenario
        self.timeScale = timeScale
    }

    private func wait(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * timeScale * 1_000_000_000))
    }

    public func discover(address: String?, timeout: TimeInterval) async throws -> [DiscoveredConsole] {
        try await wait(0.8)
        return [DiscoveredConsole(id: Self.demoConsoleID, name: "Demo Console (simulated)", kind: .ps5,
                                  address: "demo", status: .ready, systemVersion: nil)]
    }

    public func register(_ request: PairingRequest) async throws -> (ConsoleDescriptor, PairingSecret) {
        try await wait(1.0)
        let digits = request.pin.filter(\.isNumber)
        guard scenario != .pairingRejected, digits.count == 8 else { throw SessionFailure.pairingRejected }
        let descriptor = ConsoleDescriptor(id: request.console.id, name: request.console.name, kind: .ps5,
                                           lastKnownAddress: nil, isDemo: true)
        return (descriptor, PairingSecret(data: Data("demo-not-a-real-credential".utf8)))
    }

    public func openSession(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                            destination: DisplayDestination?) async throws -> ConsoleSession {
        openCount += 1
        try await wait(1.2)
        switch scenario {
        case .consoleAsleep: throw SessionFailure.consoleAsleep
        case .remotePlayDisabled: throw SessionFailure.remotePlayDisabled
        case .dropNoRecover where openCount > 1: throw SessionFailure.consoleUnreachable
        default: break
        }
        let dropAfter: Double? = (scenario == .dropThenRecover || scenario == .dropNoRecover) && openCount == 1 ? 4 : nil
        let session = MockConsoleSession(config: config, weak: scenario == .weakNetwork, dropAfter: dropAfter, timeScale: timeScale)
        lastSession = session
        return session
    }
}

public final class MockConsoleSession: ConsoleSession {
    public let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation
    private var task: Task<Void, Never>?
    private let lock = NSLock()
    private var _receivedInputs: [ControllerState] = []

    /// Inputs the "console" received — lets tests and the demo prove the input path is wired.
    public var receivedInputs: [ControllerState] { lock.lock(); defer { lock.unlock() }; return _receivedInputs }

    init(config: StreamConfig, weak: Bool, dropAfter: Double?, timeScale: Double) {
        var cont: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
        task = Task { [continuation] in
            var elapsed = 0.0
            let tick = 0.5
            while !Task.isCancelled {
                continuation.yield(.stats(StreamStats(
                    width: config.width, height: config.height,
                    framesPerSecond: weak ? Double.random(in: 38...52) : Double.random(in: 58.5...60),
                    bitrateKbps: weak ? Double.random(in: 1800...3200) : Double.random(in: 8500...10_000),
                    packetLossPercent: weak ? Double.random(in: 2.5...7) : Double.random(in: 0...0.2),
                    roundTripMs: weak ? Double.random(in: 70...140) : Double.random(in: 6...14),
                    isSimulated: true)))
                try? await Task.sleep(nanoseconds: UInt64(tick * timeScale * 1_000_000_000))
                elapsed += tick
                if let dropAfter, elapsed >= dropAfter {
                    continuation.yield(.interrupted(reason: "Simulated network drop"))
                    break
                }
            }
        }
    }

    public func send(_ input: ControllerState) {
        lock.lock(); _receivedInputs.append(input); if _receivedInputs.count > 500 { _receivedInputs.removeFirst(250) }; lock.unlock()
    }

    public func close() async {
        task?.cancel()
        continuation.finish()
    }
}
