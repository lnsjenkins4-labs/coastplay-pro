import Foundation
import Combine

/// Drives one play session: loads the pairing secret, opens the transport, forwards input,
/// and handles interruption → reconnect → failure. All state changes go through
/// `SessionStateMachine`, so the UI only ever sees valid states.
@MainActor
public final class SessionController: ObservableObject {
    @Published public private(set) var state: SessionState = .idle
    @Published public private(set) var stats: StreamStats?
    @Published public private(set) var console: ConsoleDescriptor?
    @Published public private(set) var isDemoSession = false
    /// Plain-language detail while connecting, when the source reports any (e.g. waking the console).
    @Published public private(set) var progressText: String?
    /// Whether the current session runs on the console's local network (true) or across the internet.
    @Published public private(set) var isLocalRoute = true
    @Published public var isMuted = false { didSet { destination?.setMuted(isMuted) } }

    public let maxReconnectAttempts: Int
    public let reconnectDelay: TimeInterval
    private let credentials: CredentialStore
    private var session: ConsoleSession?
    private var destination: DisplayDestination?
    private var runTask: Task<Void, Never>?
    private var generation = 0
    // Fast path for controller input: lets the controller's own queue reach the live session
    // without waiting for the main thread, which is also busy drawing the interface.
    private let fastLock = NSLock()
    nonisolated(unsafe) private var fastSession: ConsoleSession?

    public init(credentials: CredentialStore, maxReconnectAttempts: Int = 3, reconnectDelay: TimeInterval = 1.5) {
        self.credentials = credentials
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelay = reconnectDelay
    }

    public func connect(to console: ConsoleDescriptor, using source: ConsoleSource,
                        config: StreamConfig = StreamConfig(), destination: DisplayDestination? = nil) {
        guard !state.isActive else { return }
        isMuted = false          // a mute from an earlier session must not silently carry over
        generation += 1
        let gen = generation
        self.console = console
        self.isDemoSession = source.isDemo
        self.destination = destination
        self.stats = nil
        self.progressText = nil
        source.progressHandler = { [weak self] text in
            Task { @MainActor in if self?.state == .connecting || self?.state.isActive == true { self?.progressText = text } }
        }
        apply(.connectRequested)
        runTask = Task { [weak self] in
            await self?.run(gen: gen, console: console, source: source, config: config)
        }
    }

    public func disconnect() async {
        guard state.isActive else { return }
        generation += 1
        runTask?.cancel()
        runTask = nil
        await session?.close()
        session = nil
        destination?.teardown()
        destination = nil
        stats = nil
        apply(.userDisconnected)
    }

    /// Forwards controller input. Dropped unless the session is actually playing.
    public func send(_ input: ControllerState) {
        guard state == .playing else { return }
        session?.send(InputMapper.normalized(input))
    }

    /// Forwards touch/pointer input. Dropped unless playing.
    public func send(pointer: PointerEvent) {
        guard state == .playing else { return }
        session?.send(pointer: pointer)
    }

    public func send(text: String) { guard state == .playing, !text.isEmpty else { return }; session?.send(text: text) }
    public func setGameKeys(_ on: Bool) { guard state == .playing else { return }; session?.setGameKeys(on) }
    public func send(key: SpecialKey) { guard state == .playing else { return }; session?.send(key: key) }

    /// Sends controller input straight to the live session from any thread. Dropped unless playing.
    nonisolated public func sendImmediately(_ input: ControllerState) {
        fastLock.lock(); let live = fastSession; fastLock.unlock()
        live?.send(InputMapper.normalized(input))
    }

    // MARK: - Internals

    private func apply(_ event: SessionEvent) {
        if let next = SessionStateMachine.reduce(state, event) {
            state = next
            if next == .playing || !next.isActive { progressText = nil }
            fastLock.lock(); fastSession = (next == .playing) ? session : nil; fastLock.unlock()
        }
    }

    private func run(gen: Int, console: ConsoleDescriptor, source: ConsoleSource, config: StreamConfig) async {
        let secret: PairingSecret
        do {
            guard let loaded = try credentials.load(for: console.id) else {
                apply(.transportFailed(.credentialsMissing)); return
            }
            secret = loaded
        } catch {
            apply(.transportFailed(.credentialsMissing)); return
        }

        var reconnectAttempt = 0   // 0 = first connection
        while true {
            let opened: ConsoleSession
            do {
                opened = try await source.openSession(console: console, secret: secret, config: config, destination: destination)
            } catch {
                guard gen == generation else { return }
                if reconnectAttempt == 0 {
                    apply(.transportFailed((error as? SessionFailure) ?? .timedOut)); return
                }
                if reconnectAttempt >= maxReconnectAttempts {
                    apply(.transportFailed(.connectionLost)); return
                }
                reconnectAttempt += 1
                apply(.reconnectStarted(attempt: reconnectAttempt, of: maxReconnectAttempts))
                guard await pause(reconnectDelay), gen == generation else { return }
                continue
            }
            guard gen == generation else { await opened.close(); return }
            session = opened
            isLocalRoute = opened.isLocalRoute
            reconnectAttempt = 0
            apply(.transportOpened)

            var interruption: String?
            events: for await event in opened.events {
                guard gen == generation else { return }
                switch event {
                case .stats(let value):
                    stats = value
                case .interrupted(let reason):
                    interruption = reason
                    break events
                case .ended(let failure):
                    session = nil; stats = nil
                    await opened.close()
                    if let failure { apply(.transportFailed(failure)) } else { apply(.remoteEnded) }
                    return
                }
            }
            guard gen == generation else { return }
            session = nil; stats = nil
            await opened.close()
            guard let reason = interruption else { apply(.remoteEnded); return }

            apply(.transportInterrupted(reason: reason))
            reconnectAttempt = 1
            apply(.reconnectStarted(attempt: 1, of: maxReconnectAttempts))
            guard await pause(reconnectDelay), gen == generation else { return }
        }
    }

    /// Returns false if cancelled.
    private func pause(_ seconds: TimeInterval) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); return true }
        catch { return false }
    }
}
