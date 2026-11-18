import XCTest
@testable import RGPCore
import RGPMock
import RGPPS5

final class StateMachineTests: XCTestCase {
    func testHappyPath() {
        var s = SessionState.idle
        s = SessionStateMachine.reduce(s, .connectRequested)!
        XCTAssertEqual(s, .connecting)
        s = SessionStateMachine.reduce(s, .transportOpened)!
        XCTAssertEqual(s, .playing)
        s = SessionStateMachine.reduce(s, .userDisconnected)!
        XCTAssertEqual(s, .disconnected)
    }

    func testInterruptReconnectRecover() {
        var s = SessionState.playing
        s = SessionStateMachine.reduce(s, .transportInterrupted(reason: "x"))!
        XCTAssertEqual(s, .interrupted(reason: "x"))
        s = SessionStateMachine.reduce(s, .reconnectStarted(attempt: 1, of: 3))!
        XCTAssertEqual(s, .reconnecting(attempt: 1, of: 3))
        s = SessionStateMachine.reduce(s, .reconnectStarted(attempt: 2, of: 3))!
        XCTAssertEqual(s, .reconnecting(attempt: 2, of: 3))
        XCTAssertEqual(SessionStateMachine.reduce(s, .transportOpened), .playing)
        XCTAssertEqual(SessionStateMachine.reduce(s, .transportFailed(.connectionLost)), .failed(.connectionLost))
    }

    func testInvalidTransitionsAreRejected() {
        XCTAssertNil(SessionStateMachine.reduce(.idle, .transportOpened))
        XCTAssertNil(SessionStateMachine.reduce(.idle, .userDisconnected))
        XCTAssertNil(SessionStateMachine.reduce(.playing, .connectRequested))
        XCTAssertNil(SessionStateMachine.reduce(.disconnected, .transportInterrupted(reason: "late")))
        XCTAssertNil(SessionStateMachine.reduce(.failed(.timedOut), .transportOpened))
        XCTAssertNil(SessionStateMachine.reduce(.connecting, .transportInterrupted(reason: "x")))
    }

    func testRetryFromTerminalStates() {
        XCTAssertEqual(SessionStateMachine.reduce(.failed(.timedOut), .connectRequested), .connecting)
        XCTAssertEqual(SessionStateMachine.reduce(.disconnected, .connectRequested), .connecting)
    }

    func testEveryFailureHasRecoveryAdvice() {
        let all: [SessionFailure] = [.consoleUnreachable, .consoleAsleep, .remotePlayDisabled, .pairingRejected,
                                     .credentialsMissing, .consoleBusy, .connectionLost, .timedOut, .transportNotImplemented]
        for f in all {
            XCTAssertFalse(f.title.isEmpty); XCTAssertFalse(f.message.isEmpty)
            XCTAssertFalse(f.recovery.isEmpty, "\(f.code) has no recovery steps")
        }
    }
}

@MainActor
final class SessionControllerTests: XCTestCase {
    let demo = ConsoleDescriptor(id: MockConsoleSource.demoConsoleID, name: "Demo", kind: .ps5, isDemo: true)

    private func makeController(paired: Bool = true) throws -> (SessionController, InMemoryCredentialStore) {
        let store = InMemoryCredentialStore()
        if paired { try store.save(PairingSecret(data: Data([1, 2, 3])), for: demo.id) }
        return (SessionController(credentials: store, maxReconnectAttempts: 2, reconnectDelay: 0.01), store)
    }

    private func waitFor(_ controller: SessionController, timeout: TimeInterval = 5,
                         _ predicate: (SessionState) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(controller.state) { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    func testHealthyConnectStatsInputAndDisconnect() async throws {
        let (c, _) = try makeController()
        let source = MockConsoleSource(scenario: .healthy, timeScale: 0.01)
        c.connect(to: demo, using: source)
        XCTAssertEqual(c.state, .connecting)
        let playing = await waitFor(c) { $0 == .playing }
        XCTAssertTrue(playing)
        XCTAssertTrue(c.isDemoSession)

        let deadline = Date().addingTimeInterval(2)
        while c.stats == nil, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(c.stats?.isSimulated, true)

        var input = ControllerState(); input.buttons = [.cross]; input.leftX = 1
        c.send(input)
        XCTAssertEqual(source.lastSession?.receivedInputs.last?.buttons, [.cross])

        await c.disconnect()
        XCTAssertEqual(c.state, .disconnected)
        XCTAssertNil(c.stats)
    }

    func testInputIsDroppedWhenNotPlaying() async throws {
        let (c, _) = try makeController()
        c.send(ControllerState())   // idle: must not crash or queue
        XCTAssertEqual(c.state, .idle)
    }

    func testMissingCredentialsFails() async throws {
        let (c, _) = try makeController(paired: false)
        c.connect(to: demo, using: MockConsoleSource(timeScale: 0.01))
        let failed = await waitFor(c) { $0 == .failed(.credentialsMissing) }
        XCTAssertTrue(failed)
    }

    func testConsoleAsleepFailsWithAdvice() async throws {
        let (c, _) = try makeController()
        c.connect(to: demo, using: MockConsoleSource(scenario: .consoleAsleep, timeScale: 0.01))
        let failed = await waitFor(c) { $0 == .failed(.consoleAsleep) }
        XCTAssertTrue(failed)
    }

    func testDropThenRecover() async throws {
        let (c, _) = try makeController()
        let source = MockConsoleSource(scenario: .dropThenRecover, timeScale: 0.01)
        var seen: [String] = []
        let sub = c.$state.sink { seen.append($0.label) }
        c.connect(to: demo, using: source)
        let recovered = await waitFor(c) { _ in source.openCount == 2 && c.state == .playing }
        XCTAssertTrue(recovered)
        XCTAssertTrue(seen.contains("Interrupted"))
        XCTAssertTrue(seen.contains("Reconnecting (1 of 2)…"))
        sub.cancel()
        await c.disconnect()
    }

    func testDropNoRecoverEndsInConnectionLost() async throws {
        let (c, _) = try makeController()
        let source = MockConsoleSource(scenario: .dropNoRecover, timeScale: 0.01)
        c.connect(to: demo, using: source)
        let failed = await waitFor(c) { $0 == .failed(.connectionLost) }
        XCTAssertTrue(failed)
        XCTAssertEqual(source.openCount, 3)   // first connect + 2 reconnect attempts
    }

    func testDisconnectWhileConnectingCancels() async throws {
        let (c, _) = try makeController()
        let source = MockConsoleSource(scenario: .healthy, timeScale: 0.2)
        c.connect(to: demo, using: source)
        await c.disconnect()
        XCTAssertEqual(c.state, .disconnected)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(c.state, .disconnected, "a late transport open must not revive the session")
    }

    func testRealPS5SourceRefusesToPretend() async throws {
        let (c, store) = try makeController()
        let real = ConsoleDescriptor(id: "real", name: "PS5", kind: .ps5, isDemo: false)
        try store.save(PairingSecret(data: Data([9])), for: "real")
        c.connect(to: real, using: PS5ConsoleSource())
        let failed = await waitFor(c) { $0 == .failed(.transportNotImplemented) }
        XCTAssertTrue(failed)
        XCTAssertFalse(c.isDemoSession)
    }
}

final class MockPairingTests: XCTestCase {
    let console = DiscoveredConsole(id: "demo-console", name: "Demo", kind: .ps5, address: "demo", status: .ready)

    func testPairingAcceptsEightDigitPin() async throws {
        let (descriptor, _) = try await MockConsoleSource(timeScale: 0.01).register(.init(console: console, pin: "1234 5678"))
        XCTAssertTrue(descriptor.isDemo)
    }

    func testPairingRejectsShortPinAndRejectScenario() async {
        do { _ = try await MockConsoleSource(timeScale: 0.01).register(.init(console: console, pin: "123")); XCTFail() }
        catch { XCTAssertEqual(error as? SessionFailure, .pairingRejected) }
        do { _ = try await MockConsoleSource(scenario: .pairingRejected, timeScale: 0.01).register(.init(console: console, pin: "12345678")); XCTFail() }
        catch { XCTAssertEqual(error as? SessionFailure, .pairingRejected) }
    }
}

final class SecurityTests: XCTestCase {
    func testPairingSecretNeverPrints() {
        let secret = PairingSecret(data: Data("super-secret-key".utf8))
        for text in ["\(secret)", String(describing: secret), String(reflecting: secret)] {
            XCTAssertFalse(text.contains("super"))
            XCTAssertTrue(text.contains("redacted"))
        }
    }

    func testForgetRemovesCredential() throws {
        let store = InMemoryCredentialStore()
        try store.save(PairingSecret(data: Data([1])), for: "a")
        try store.delete(for: "a")
        XCTAssertNil(try store.load(for: "a"))
    }
}

final class InputTests: XCTestCase {
    func testDeadZone() {
        let small = InputMapper.applyDeadZone(x: 0.05, y: 0.02)
        XCTAssertEqual(small.x, 0); XCTAssertEqual(small.y, 0)
        let full = InputMapper.applyDeadZone(x: 1, y: 0)
        XCTAssertEqual(full.x, 1, accuracy: 0.0001)
        let half = InputMapper.applyDeadZone(x: 0, y: -0.54)
        XCTAssertEqual(half.y, -0.5, accuracy: 0.0001)
    }

    func testTriggersAreClamped() {
        var s = ControllerState(); s.l2 = 1.4; s.r2 = -0.2
        let n = InputMapper.normalized(s)
        XCTAssertEqual(n.l2, 1); XCTAssertEqual(n.r2, 0)
    }
}

final class PS5DiscoveryTests: XCTestCase {
    func testSearchMessage() {
        let text = String(data: PS5Discovery.searchMessage(), encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("SRCH * HTTP/1.1\n"))
        XCTAssertTrue(text.contains("device-discovery-protocol-version:00030010"))
    }

    func testParsesReadyReply() {
        let reply = "HTTP/1.1 200 Ok\nhost-id:AABBCCDDEEFF\nhost-type:PS5\nhost-name:Living Room\nhost-request-port:997\ndevice-discovery-protocol-version:00030010\nsystem-version:09000004\n"
        let c = PS5Discovery.parseResponse(Data(reply.utf8), from: "192.168.1.20")
        XCTAssertEqual(c?.id, "AABBCCDDEEFF"); XCTAssertEqual(c?.name, "Living Room")
        XCTAssertEqual(c?.status, .ready); XCTAssertEqual(c?.address, "192.168.1.20")
    }

    func testParsesStandbyReply() {
        let reply = "HTTP/1.1 620 Server Standby\r\nhost-id:AABBCCDDEEFF\r\nhost-type:PS5\r\nhost-name:PS5-1\r\n"
        XCTAssertEqual(PS5Discovery.parseResponse(Data(reply.utf8), from: "10.0.0.2")?.status, .standby)
    }

    func testRejectsNonPS5AndGarbage() {
        XCTAssertNil(PS5Discovery.parseResponse(Data("HTTP/1.1 200 Ok\nhost-id:X\nhost-type:PS4\n".utf8), from: "x"))
        XCTAssertNil(PS5Discovery.parseResponse(Data([0xFF, 0xFE, 0x00]), from: "x"))
        XCTAssertNil(PS5Discovery.parseResponse(Data("hello".utf8), from: "x"))
    }
}

final class CompatibilityTests: XCTestCase {
    func testNothingIsClaimedVerifiedYet() {
        XCTAssertTrue(CompatibilityEntry.matrix.allSatisfy { $0.status != .hardwareVerified },
                      "Do not mark a device hardware-verified without a recorded real-session test.")
    }
}

import RGPMirror

final class MirrorProtocolTests: XCTestCase {
    func testFramesSurviveArbitrarySplitting() {
        let a = MirrorProtocol.frame(.video, Data([1, 2, 3, 4, 5]))
        let b = MirrorProtocol.frame(.audio, Data())
        let c = MirrorProtocol.frame(.hello, Data("{}".utf8))
        let stream = a + b + c
        var parser = MirrorFrameParser()
        var seen: [(MirrorProtocol.MessageType, Data)] = []
        for byte in stream { seen += parser.append(Data([byte])) }
        XCTAssertEqual(seen.map { $0.0 }, [.video, .audio, .hello])
        XCTAssertEqual(seen[0].1, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(seen[1].1.count, 0)
        XCTAssertFalse(parser.corrupt)
    }

    func testUnknownTypeAndOversizeAreRejected() {
        var parser = MirrorFrameParser()
        XCTAssertTrue(parser.append(Data([99, 0, 0, 0, 0])).isEmpty)
        XCTAssertTrue(parser.corrupt)
        var big = MirrorFrameParser()
        XCTAssertTrue(big.append(Data([2, 0xFF, 0xFF, 0xFF, 0xFF])).isEmpty)
        XCTAssertTrue(big.corrupt)
    }

    func testControllerRoundTrip() {
        var s = ControllerState()
        s.buttons = [.cross, .dpadLeft, .ps]; s.leftX = -0.5; s.leftY = 1; s.rightY = 0.25; s.r2 = 0.75
        XCTAssertEqual(MirrorProtocol.unpackController(MirrorProtocol.pack(s)), s)
        XCTAssertNil(MirrorProtocol.unpackController(Data([1, 2, 3])))
    }

    func testPointerRoundTripAndClamping() {
        let e = PointerEvent(x: 0.25, y: 0.75, phase: .down)
        XCTAssertEqual(MirrorProtocol.unpackPointer(MirrorProtocol.pack(e)), e)
        let wild = MirrorProtocol.unpackPointer(MirrorProtocol.pack(PointerEvent(x: 9, y: -3, phase: .move)))
        XCTAssertEqual(wild, PointerEvent(x: 1, y: 0, phase: .move))
        XCTAssertNil(MirrorProtocol.unpackPointer(Data([7, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testXboxPlaceholderRefusesHonestly() async {
        let xbox = XboxConsoleSource()
        XCTAssertFalse(xbox.supportsPairing)
        let found = try? await xbox.discover(address: nil, timeout: 0.1)
        XCTAssertEqual(found?.count, 0)
    }
}
