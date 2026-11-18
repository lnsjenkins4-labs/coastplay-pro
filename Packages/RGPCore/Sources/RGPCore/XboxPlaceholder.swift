import Foundation

/// Xbox readiness: the extension point exists and the app can show Xbox as a device type, but
/// there is NO Xbox code here. Nothing has been sent to or received from an Xbox, and nothing
/// has been tested (the owner has no Xbox). See docs/ARCHITECTURE.md, "Xbox".
public final class XboxConsoleSource: ConsoleSource {
    public let kind: ConsoleKind = .xbox
    public let isDemo = false
    public let supportsPairing = false
    public init() {}

    public var setupSteps: [String] {
        ["Xbox support is not built. This screen is a placeholder so the app is ready for it.",
         "When built, it will use a Microsoft sign-in on Microsoft's own page; this app will never ask for that password."]
    }
    public var unavailableNote: String { "Xbox is not supported yet. Nothing was sent to any Xbox." }

    public func discover(address: String?, timeout: TimeInterval) async throws -> [DiscoveredConsole] { [] }

    public func register(_ request: PairingRequest) async throws -> (ConsoleDescriptor, PairingSecret) {
        throw SessionFailure.xboxNotBuilt
    }

    public func openSession(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                            destination: DisplayDestination?) async throws -> ConsoleSession {
        throw SessionFailure.xboxNotBuilt
    }
}

public extension SessionFailure {
    static let xboxNotBuilt = SessionFailure(
        code: .transportNotImplemented, title: "Xbox isn't supported yet",
        message: "The app has a place for Xbox, but no Xbox connection has been built or tested.",
        recovery: ["Use a PlayStation 5 or a computer for now."], canRetry: false)
}
