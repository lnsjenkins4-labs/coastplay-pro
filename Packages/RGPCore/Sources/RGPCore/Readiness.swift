import Foundation

/// What has actually been observed for one saved console. Each step is recorded separately
/// because none of them implies the next: a paired console may never connect, a connection may
/// show no picture, and a picture does not prove the controller works.
public struct ReadinessRecord: Codable, Equatable, Sendable {
    public var registeredAt: Date?
    public var connectedAt: Date?
    public var streamDisplayedAt: Date?
    /// The app sent controller input during a live session. Not proof the console reacted.
    public var inputSentAt: Date?
    /// The person confirmed the console reacted to their controller (nil = not asked yet).
    public var inputConfirmedByUser: Bool?
    /// A session with picture succeeded while connected to the console's own local network.
    public var homeTestedAt: Date?
    /// A session with picture succeeded from a different network. One success proves that
    /// route worked that time, not that every network will.
    public var awayTestedAt: Date?

    public init() {}

    public enum Step: String, CaseIterable, Sendable {
        case registered = "Paired with the console"
        case connected = "Connection established"
        case streamDisplayed = "Picture received"
        case inputConfirmed = "Controller confirmed"
    }

    public func isDone(_ step: Step) -> Bool {
        switch step {
        case .registered: return registeredAt != nil
        case .connected: return connectedAt != nil
        case .streamDisplayed: return streamDisplayedAt != nil
        case .inputConfirmed: return inputConfirmedByUser == true
        }
    }

    public var isFullyConfirmed: Bool { Step.allCases.allSatisfy(isDone) }

    public enum AwayStatus: Sendable { case tested(Date), notTested }
    public var awayStatus: AwayStatus { awayTestedAt.map { .tested($0) } ?? .notTested }
}

public enum NetworkAddress {
    /// True for addresses that only exist on a local network (so a session to one is a home-network session).
    public static func isLocal(_ address: String?) -> Bool {
        guard let address else { return false }
        if address.hasPrefix("bonjour:") { return true }
        let host = address.split(separator: ":").first.map(String.init) ?? address
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254) { return true }
        return parts[0] == 172 && (16...31).contains(parts[1])
    }
}
