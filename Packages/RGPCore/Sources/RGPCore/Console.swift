import Foundation

// MARK: - A. Console connection contracts

public enum ConsoleKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case ps5
    /// A Mac or PC running our own host app ("mirroring").
    case computer
    /// Extension point only. No Xbox code exists and nothing has been tested.
    case xbox

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ps5: return "PlayStation 5"
        case .computer: return "Computer"
        case .xbox: return "Xbox"
        }
    }
}

/// Touch or pointer input for sources that have a pointer (a computer). Coordinates are 0...1
/// across the picture, origin top-left.
public struct PointerEvent: Sendable, Equatable {
    public enum Phase: UInt8, Sendable { case move = 0, down = 1, up = 2, secondaryClick = 3 }
    public var x: Float
    public var y: Float
    public var phase: Phase
    public init(x: Float, y: Float, phase: Phase) { self.x = x; self.y = y; self.phase = phase }
}

/// Non-secret, persistable description of a paired console.
public struct ConsoleDescriptor: Codable, Identifiable, Hashable, Sendable {
    public var id: String              // stable host identifier
    public var name: String
    public var kind: ConsoleKind
    public var lastKnownAddress: String?
    public var isDemo: Bool            // true = created by mock mode, never a real console
    public var lastConnected: Date?

    public init(id: String, name: String, kind: ConsoleKind, lastKnownAddress: String? = nil,
                isDemo: Bool, lastConnected: Date? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.lastKnownAddress = lastKnownAddress; self.isDemo = isDemo; self.lastConnected = lastConnected
    }
}

/// Opaque pairing material produced by console registration. Never logged: its
/// description is always redacted, and it is deliberately not Codable so it cannot
/// be swept into a JSON settings file by accident.
public struct PairingSecret: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let data: Data
    public init(data: Data) { self.data = data }
    public var description: String { "<redacted pairing secret>" }
    public var debugDescription: String { description }
}

/// Device-secure storage for pairing material (Keychain on iOS, Keystore on Android).
public protocol CredentialStore: AnyObject {
    func save(_ secret: PairingSecret, for consoleID: String) throws
    func load(for consoleID: String) throws -> PairingSecret?
    func delete(for consoleID: String) throws
}

/// In-memory store for tests and previews only.
public final class InMemoryCredentialStore: CredentialStore {
    private var items: [String: PairingSecret] = [:]
    public init() {}
    public func save(_ secret: PairingSecret, for consoleID: String) throws { items[consoleID] = secret }
    public func load(for consoleID: String) throws -> PairingSecret? { items[consoleID] }
    public func delete(for consoleID: String) throws { items[consoleID] = nil }
}

public struct DiscoveredConsole: Identifiable, Hashable, Sendable {
    public enum Status: String, Sendable { case ready, standby, unknown }
    public var id: String
    public var name: String
    public var kind: ConsoleKind
    public var address: String
    public var status: Status
    public var systemVersion: String?
    public init(id: String, name: String, kind: ConsoleKind, address: String, status: Status, systemVersion: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.address = address
        self.status = status; self.systemVersion = systemVersion
    }
}

/// What the user supplies to pair. The console shows the PIN on its own screen.
/// There is intentionally no password field anywhere in this type.
public struct PairingRequest: Sendable {
    public var console: DiscoveredConsole
    public var pin: String
    /// Console-account identifier obtained through the console vendor's own sign-in page
    /// (never typed into our UI as a password). Optional because the mock does not need it.
    public var accountIdentifier: String?
    public init(console: DiscoveredConsole, pin: String, accountIdentifier: String? = nil) {
        self.console = console; self.pin = pin; self.accountIdentifier = accountIdentifier
    }
}

public struct StreamConfig: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var maxBitrateKbps: Int
    /// Picture size to ask for when the session is opened across the internet. A smaller
    /// picture means less data per frame, which can cut delay on slower connections.
    /// nil = same as at home.
    public var awayWidth: Int?
    public var awayHeight: Int?
    /// Picture data rate to ask the console for. nil = the engine's own value for the picture size.
    public var requestedBitrateKbps: Int?
    public var awayRequestedBitrateKbps: Int?
    public init(width: Int = 1280, height: Int = 720, fps: Int = 60, maxBitrateKbps: Int = 10_000) {
        self.width = width; self.height = height; self.fps = fps; self.maxBitrateKbps = maxBitrateKbps
    }

    /// The settings to use for an away-from-home session.
    public var forAway: StreamConfig {
        var copy = self
        if let awayWidth, let awayHeight { copy.width = awayWidth; copy.height = awayHeight }
        copy.requestedBitrateKbps = awayRequestedBitrateKbps
        return copy
    }
}

/// Events a live transport reports upward. The session controller owns all state decisions.
public enum TransportEvent: Sendable {
    case stats(StreamStats)
    case interrupted(reason: String)
    case ended(SessionFailure?)       // nil = clean end from the console side
}

/// One open connection to a console.
public protocol ConsoleSession: AnyObject {
    var events: AsyncStream<TransportEvent> { get }
    func send(_ input: ControllerState)
    /// Pointer input. Sources without a pointer ignore it.
    func send(pointer: PointerEvent)
    /// Typed text and special keys. Sources without a keyboard ignore them.
    func send(text: String)
    func send(key: SpecialKey)
    /// Computer sessions: should the controller act as game keys (true) or as a mouse (false)?
    func setGameKeys(_ on: Bool)
    /// True when this session runs over the console's own local network; false when it was
    /// set up across the internet. Decided by how the session was actually opened.
    var isLocalRoute: Bool { get }
    func close() async
}

public extension ConsoleSession {
    func send(pointer: PointerEvent) {}
    func send(text: String) {}
    func send(key: SpecialKey) {}
    func setGameKeys(_ on: Bool) {}
    var isLocalRoute: Bool { true }
}

/// Sign-in with the console vendor's own account, done on the vendor's own web page.
/// Our code never asks for, sees in a form of ours, or stores the password. What comes back is
/// an opaque blob (tokens and the account identifier) that the app keeps in secure storage.
public protocol AccountSignIn: AnyObject {
    /// Shown to the person, e.g. "PlayStation".
    var providerName: String { get }
    /// The vendor's sign-in page to load.
    func makeSignInURL() -> URL
    /// When the web view is about to load an address starting with this, sign-in has finished.
    var redirectPrefix: String { get }
    /// Finishes sign-in from the final redirect address. Returns the blob to store securely.
    func complete(redirect: URL) async throws -> Data
    /// The account identifier pairing needs, read from a stored blob.
    func accountIdentifier(from stored: Data) -> String?
}

/// Optional: a source that can get ready for away-from-home play while the device is at home
/// (for example by noting the home's internet address). Called when the app opens or returns.
public protocol AwayPreparing: AnyObject {
    func prepareForAway(consoles: [ConsoleDescriptor]) async
}

/// Extension point for console types. PS5 is first; other sources implement this same protocol.
public protocol ConsoleSource: AnyObject {
    var kind: ConsoleKind { get }
    /// True only for simulated sources. UI must label anything from a demo source as a demo.
    var isDemo: Bool { get }
    /// `address` nil = search the whole local network; otherwise ask that one address.
    func discover(address: String?, timeout: TimeInterval) async throws -> [DiscoveredConsole]
    func register(_ request: PairingRequest) async throws -> (ConsoleDescriptor, PairingSecret)
    func openSession(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                     destination: DisplayDestination?) async throws -> ConsoleSession
    /// False when this source can find consoles but cannot pair or stream yet.
    var supportsPairing: Bool { get }
    /// True when pairing needs the console-account identifier in `PairingRequest`.
    var requiresAccountIdentifier: Bool { get }
    /// What the person does on the console or computer before searching.
    var setupSteps: [String] { get }
    /// Where to find the 8-digit pairing number.
    var pairingHint: String { get }
    /// Shown instead of the pairing form when `supportsPairing` is false.
    var unavailableNote: String { get }
    /// Called with short plain-language progress while a session is being opened
    /// (for example "Waking the console…"). May be called from any thread.
    var progressHandler: ((String) -> Void)? { get set }
    /// Non-nil when this source can sign in to the vendor account instead of asking for an identifier.
    var accountSignIn: AccountSignIn? { get }
    /// The stored vendor-account blob, handed in by the app (which keeps it in secure storage).
    /// Needed for connections that go through the vendor's network.
    var account: Data? { get set }
    /// Called when the source has refreshed the blob (new tokens) so the app can store it.
    var onAccountUpdated: ((Data) -> Void)? { get set }
    /// Called with (console id, new address) when the source finds a saved console at a
    /// different address on the home network, so the app can remember it.
    var onConsoleMoved: ((String, String) -> Void)? { get set }
}

public extension ConsoleSource {
    var progressHandler: ((String) -> Void)? { get { nil } set {} }
    var accountSignIn: AccountSignIn? { nil }
    var account: Data? { get { nil } set {} }
    var onAccountUpdated: ((Data) -> Void)? { get { nil } set {} }
    var onConsoleMoved: ((String, String) -> Void)? { get { nil } set {} }
    var supportsPairing: Bool { true }
    var requiresAccountIdentifier: Bool { false }
    var setupSteps: [String] {
        ["Turn the PlayStation on and sign in to your profile.",
         "Go to Settings → System → Remote Play and turn on Enable Remote Play.",
         "Go to Settings → System → Power Saving → Features Available in Rest Mode. Turn on Stay Connected to the Internet and Enable Turning On PS5 from Network.",
         "Make sure the PlayStation and this device are on the same home network. A network cable into the PlayStation works best, but Wi-Fi is fine."]
    }
    var pairingHint: String { "On the PlayStation, open Settings → System → Remote Play → Pair Device. Your TV shows an 8-digit number. Type it below. The number changes every few minutes, so use the one showing now." }
    var unavailableNote: String {
        "This build only sent a discovery request. Pairing and live streaming with a real PS5 are not in this build. Turn on Demo mode to try the rest of the app."
    }
}
