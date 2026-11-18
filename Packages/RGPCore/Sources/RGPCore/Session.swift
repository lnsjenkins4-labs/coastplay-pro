import Foundation

// MARK: - E. Session management

/// A failure the player can act on. `message` says what happened, `recovery` says what to do.
public struct SessionFailure: Error, Equatable, Sendable {
    public enum Code: String, Sendable {
        case consoleUnreachable, consoleAsleep, remotePlayDisabled, pairingRejected, credentialsMissing
        case consoleBusy, connectionLost, timedOut, transportNotImplemented, unknown
    }
    public var code: Code
    public var title: String
    public var message: String
    public var recovery: [String]
    public var canRetry: Bool

    public init(code: Code, title: String, message: String, recovery: [String], canRetry: Bool = true) {
        self.code = code; self.title = title; self.message = message; self.recovery = recovery; self.canRetry = canRetry
    }

    public static let consoleUnreachable = SessionFailure(
        code: .consoleUnreachable, title: "Can't reach the console",
        message: "The console did not answer. The app can't tell from here whether it is switched off, in rest mode without network features, or on a different network.",
        recovery: ["Check the console is switched on, or in rest mode with “Stay Connected to the Internet” turned on.",
                   "Make sure this device is on the same network as the console.",
                   "Away from home? Sign in with PlayStation in Settings first. Some mobile and public networks still block this kind of connection."])
    public static let consoleAsleep = SessionFailure(
        code: .consoleAsleep, title: "Console is in rest mode",
        message: "The console answered that it is in rest mode, and it did not wake up when asked.",
        recovery: ["On the console, enable “Stay Connected to the Internet” and “Enable Turning On PS5 from Network” under Power Saving.",
                   "Or wake the console with its controller, then try again."])
    public static let remotePlayDisabled = SessionFailure(
        code: .remotePlayDisabled, title: "Remote Play is turned off",
        message: "The console refused the connection because Remote Play is disabled.",
        recovery: ["On the console open Settings → System → Remote Play and turn on Enable Remote Play."])
    public static let pairingRejected = SessionFailure(
        code: .pairingRejected, title: "Pairing was rejected",
        message: "The console did not accept the pairing details.",
        recovery: ["Get a fresh PIN on the console: Settings → System → Remote Play → Pair Device.",
                   "PINs expire after a few minutes; enter it promptly."], canRetry: false)
    public static let credentialsMissing = SessionFailure(
        code: .credentialsMissing, title: "This console needs pairing again",
        message: "No saved pairing was found on this device for that console.",
        recovery: ["Open Console Setup and pair the console again."], canRetry: false)
    public static let consoleBusy = SessionFailure(
        code: .consoleBusy, title: "Console is in use",
        message: "Another Remote Play session or user is active on the console.",
        recovery: ["Close the other session, then try again."])
    public static let connectionLost = SessionFailure(
        code: .connectionLost, title: "Connection lost",
        message: "The stream stopped and could not be restored automatically.",
        recovery: ["Check your network connection.", "Move closer to the Wi-Fi router or use a wired connection for the console.", "Try again."])
    public static let timedOut = SessionFailure(
        code: .timedOut, title: "Connection timed out",
        message: "The console took too long to respond.",
        recovery: ["Try again.", "Restart the console if this keeps happening."])
    public static let transportNotImplemented = SessionFailure(
        code: .transportNotImplemented, title: "Real PS5 streaming isn't built yet",
        message: "This build can find a PS5 on your network, but pairing and live streaming are not implemented. Nothing was sent to your console beyond a discovery request.",
        recovery: ["Use Demo Mode to try the interface.", "See docs/TECH_DECISION.md for the remaining step."], canRetry: false)
}

public enum SessionState: Equatable, Sendable {
    case idle
    case connecting
    case playing
    case interrupted(reason: String)
    case reconnecting(attempt: Int, of: Int)
    case failed(SessionFailure)
    case disconnected

    public var isActive: Bool {
        switch self {
        case .connecting, .playing, .interrupted, .reconnecting: return true
        case .idle, .failed, .disconnected: return false
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .playing: return "Playing"
        case .interrupted: return "Interrupted"
        case .reconnecting(let attempt, let max): return "Reconnecting (\(attempt) of \(max))…"
        case .failed: return "Failed"
        case .disconnected: return "Disconnected"
        }
    }
}

public enum SessionEvent: Equatable, Sendable {
    case connectRequested
    case transportOpened
    case transportInterrupted(reason: String)
    case reconnectStarted(attempt: Int, of: Int)
    case transportFailed(SessionFailure)
    case remoteEnded
    case userDisconnected
}

/// Pure transition table. Returns nil for transitions that are not allowed, so that
/// stale or out-of-order transport callbacks cannot move the session somewhere invalid.
public enum SessionStateMachine {
    public static func reduce(_ state: SessionState, _ event: SessionEvent) -> SessionState? {
        switch (state, event) {
        case (.idle, .connectRequested), (.failed, .connectRequested), (.disconnected, .connectRequested):
            return .connecting

        case (.connecting, .transportOpened), (.reconnecting, .transportOpened):
            return .playing

        case (.playing, .transportInterrupted(let reason)):
            return .interrupted(reason: reason)

        case (.interrupted, .reconnectStarted(let attempt, let max)),
             (.reconnecting, .reconnectStarted(let attempt, let max)):
            return .reconnecting(attempt: attempt, of: max)

        case (.connecting, .transportFailed(let failure)), (.playing, .transportFailed(let failure)),
             (.interrupted, .transportFailed(let failure)), (.reconnecting, .transportFailed(let failure)):
            return .failed(failure)

        case (.playing, .remoteEnded), (.interrupted, .remoteEnded):
            return .disconnected

        case (.connecting, .userDisconnected), (.playing, .userDisconnected),
             (.interrupted, .userDisconnected), (.reconnecting, .userDisconnected):
            return .disconnected

        default:
            return nil
        }
    }
}
