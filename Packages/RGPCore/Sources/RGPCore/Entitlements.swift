import Foundation

// MARK: - Plans and access
//
// Owner's pricing direction (2026-11-17). Two tiers, each sold monthly or annually:
//   Single Platform  $20.00 / year   $4.99 / month   one chosen gaming-source platform
//   All Access       $29.99 / year   $5.99 / month   every supported gaming-source platform
// A "platform" is a gaming SOURCE (PS5, PC, …). It is not a limit on how many consoles a
// person registers, and the device they play ON (iPhone, iPad, …) never needs a higher tier.
// Everything here is plain logic so it can be tested without the App Store.

/// A gaming source a plan can cover.
public enum SourcePlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case ps5, pc, xbox
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ps5: return "PlayStation 5"
        case .pc: return "PC"
        case .xbox: return "Xbox"
        }
    }
    public init(_ kind: ConsoleKind) {
        switch kind {
        case .ps5: self = .ps5
        case .computer: self = .pc
        case .xbox: self = .xbox
        }
    }
}

/// Which sources are really supported right now. Only verified sources belong here; adding one
/// later is a one-line change and needs no change to the plans.
public struct PlatformAvailability: Sendable, Equatable {
    public var available: [SourcePlatform]
    public init(available: [SourcePlatform]) { self.available = available }
    /// 2026-11-17: PS5 is the only source confirmed working on real hardware.
    public static let current = PlatformAvailability(available: [.ps5])
    public func isAvailable(_ platform: SourcePlatform) -> Bool { available.contains(platform) }
}

public enum PlanTier: String, Codable, Sendable, CaseIterable {
    case single, allAccess
    public var displayName: String { self == .single ? "Single Platform" : "All Access" }
    /// Apple's subscription-group rank: 1 is the highest level of service.
    public var groupLevel: Int { self == .allAccess ? 1 : 2 }
}

public enum BillingInterval: String, Codable, Sendable, CaseIterable {
    case monthly, annual
    public var displayName: String { self == .monthly ? "Monthly" : "Yearly" }
    public var perText: String { self == .monthly ? "per month" : "per year" }
}

public struct PlanProduct: Identifiable, Sendable, Equatable {
    public let id: String                 // App Store product identifier
    public let tier: PlanTier
    public let interval: BillingInterval
    /// The owner's US price. The price actually charged is always the one the store reports.
    public let referencePriceUSD: Decimal
    public var referencePriceText: String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.locale = Locale(identifier: "en_US")
        return f.string(from: referencePriceUSD as NSDecimalNumber) ?? "$\(referencePriceUSD)"
    }
}

public enum PlanCatalog {
    /// All four are sold in ONE subscription group, so a person can hold only one at a time.
    public static let subscriptionGroupName = "CoastPlay PRO Access"
    public static let singleAnnual  = PlanProduct(id: "coastplaypro.single.annual",  tier: .single,    interval: .annual,  referencePriceUSD: Decimal(string: "20.00")!)
    public static let singleMonthly = PlanProduct(id: "coastplaypro.single.monthly", tier: .single,    interval: .monthly, referencePriceUSD: Decimal(string: "4.99")!)
    public static let allAnnual     = PlanProduct(id: "coastplaypro.all.annual",     tier: .allAccess, interval: .annual,  referencePriceUSD: Decimal(string: "29.99")!)
    public static let allMonthly    = PlanProduct(id: "coastplaypro.all.monthly",    tier: .allAccess, interval: .monthly, referencePriceUSD: Decimal(string: "5.99")!)
    public static let all: [PlanProduct] = [singleAnnual, singleMonthly, allAnnual, allMonthly]

    public static func product(id: String) -> PlanProduct? { all.first { $0.id == id } }
    public static func product(_ tier: PlanTier, _ interval: BillingInterval) -> PlanProduct {
        all.first { $0.tier == tier && $0.interval == interval }!
    }
}

/// What the store says about the person's subscription right now.
public enum SubscriptionState: String, Codable, Sendable {
    /// Paid up, or cancelled but still inside the period already paid for.
    case active
    /// Payment failed; the store is retrying and has granted a grace period. Access continues.
    case inGracePeriod
    /// Payment failed and there is no grace period. Access stops until payment succeeds.
    case inBillingRetry
    case expired
    /// Refunded or otherwise taken back by the store. Access stops at once.
    case revoked

    public var grantsAccess: Bool { self == .active || self == .inGracePeriod }
}

public struct Entitlement: Codable, Equatable, Sendable {
    public var productID: String
    public var state: SubscriptionState
    public var expires: Date?
    /// False once the person has cancelled: access continues until `expires`, then stops.
    public var willRenew: Bool
    public init(productID: String, state: SubscriptionState, expires: Date? = nil, willRenew: Bool = true) {
        self.productID = productID; self.state = state; self.expires = expires; self.willRenew = willRenew
    }
    public var product: PlanProduct? { PlanCatalog.product(id: productID) }
    public var tier: PlanTier? { product?.tier }

    public func isCurrent(at now: Date = Date()) -> Bool {
        guard state.grantsAccess else { return false }
        if state == .active, let expires, expires < now { return false }
        return true
    }
}

public enum AccessDecision: Equatable, Sendable {
    case allowed
    /// No current subscription.
    case needsPlan
    /// Single Platform is active but no platform has been chosen yet.
    case needsPlatformChoice
    /// Single Platform is active for a different platform.
    case notIncluded(selected: SourcePlatform)
    /// We don't support this source yet, whatever the plan.
    case notAvailableYet
}

public enum PlanChange: Equatable, Sendable {
    /// Higher level of service: the store switches at once and refunds the unused part.
    case upgrade
    /// Lower level of service: takes effect at the next renewal.
    case downgrade
    /// Same level, different billing interval.
    case crossgrade
    case none
}

public enum EntitlementRules {
    /// May this person play from this source right now?
    public static func access(to platform: SourcePlatform, entitlement: Entitlement?, selectedPlatform: SourcePlatform?,
                              availability: PlatformAvailability = .current, now: Date = Date()) -> AccessDecision {
        guard availability.isAvailable(platform) else { return .notAvailableYet }
        guard let entitlement, entitlement.isCurrent(at: now), let tier = entitlement.tier else { return .needsPlan }
        switch tier {
        case .allAccess: return .allowed
        case .single:
            guard let selected = effectiveSelection(selectedPlatform, availability: availability) else { return .needsPlatformChoice }
            return selected == platform ? .allowed : .notIncluded(selected: selected)
        }
    }

    /// With only one supported platform there is nothing to choose, so it is chosen for them.
    public static func effectiveSelection(_ selected: SourcePlatform?, availability: PlatformAvailability = .current) -> SourcePlatform? {
        if let selected, availability.isAvailable(selected) { return selected }
        return availability.available.count == 1 ? availability.available[0] : nil
    }

    /// The platforms a plan covers today. All Access grows by itself as sources are enabled.
    public static func includedPlatforms(tier: PlanTier, selectedPlatform: SourcePlatform?,
                                         availability: PlatformAvailability = .current) -> [SourcePlatform] {
        switch tier {
        case .allAccess: return availability.available
        case .single: return effectiveSelection(selectedPlatform, availability: availability).map { [$0] } ?? []
        }
    }

    /// The best of several store records (for example after a restore): access first, then tier.
    public static func best(_ entitlements: [Entitlement], now: Date = Date()) -> Entitlement? {
        entitlements.filter { $0.product != nil }.max { a, b in
            let ka = (a.isCurrent(at: now) ? 1 : 0, -(a.tier?.groupLevel ?? 9))
            let kb = (b.isCurrent(at: now) ? 1 : 0, -(b.tier?.groupLevel ?? 9))
            return ka < kb
        }
    }

    public static func change(from: PlanProduct, to: PlanProduct) -> PlanChange {
        if from == to { return .none }
        if to.tier.groupLevel < from.tier.groupLevel { return .upgrade }
        if to.tier.groupLevel > from.tier.groupLevel { return .downgrade }
        return .crossgrade
    }

    /// What the plan screen says a tier includes, in the customer's words.
    public static func accessSummary(tier: PlanTier, availability: PlatformAvailability = .current) -> String {
        let names = availability.available.map(\.displayName)
        let list = ListFormatter.localizedString(byJoining: names)
        switch tier {
        case .single:
            return names.count == 1 ? "\(list). One gaming platform of your choice as more are added."
                                    : "One of: \(list). You choose."
        case .allAccess:
            return names.count == 1 ? "\(list) today, plus every gaming platform we add while you're subscribed."
                                    : "\(list), plus every gaming platform we add while you're subscribed."
        }
    }
}
