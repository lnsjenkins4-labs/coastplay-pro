import Foundation
import StoreKit
import RGPCore

/// Talks to the App Store (StoreKit 2) and turns what it says into an `Entitlement`. All the
/// rules about who may play what live in `EntitlementRules`, which is tested separately.
@MainActor
final class StoreManager: ObservableObject {
    enum LoadState: Equatable { case idle, loading, loaded, unavailable }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var entitlement: Entitlement?
    /// Set when the store says the last renewal could not be charged, or access was taken back.
    @Published private(set) var problem: SubscriptionState?
    @Published private(set) var loadState = LoadState.idle
    @Published var message: String?
    @Published private(set) var busy = false

    /// Single Platform: the platform the person chose. With one supported platform it is implied.
    @Published var selectedPlatform: SourcePlatform? {
        didSet { UserDefaults.standard.set(selectedPlatform?.rawValue, forKey: "plan.selectedPlatform") }
    }

    private var updates: Task<Void, Never>?

    init() {
        selectedPlatform = UserDefaults.standard.string(forKey: "plan.selectedPlatform").flatMap(SourcePlatform.init(rawValue:))
        // Renewals, refunds and purchases approved later arrive here, even while the app is closed.
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await loadProducts(); await refresh() }
    }

    deinit { updates?.cancel() }

    func loadProducts() async {
        loadState = .loading
        do {
            let list = try await Product.products(for: PlanCatalog.all.map(\.id))
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            loadState = list.isEmpty ? .unavailable : .loaded
        } catch {
            loadState = .unavailable
        }
    }

    /// Re-reads what the store says this person currently owns.
    func refresh() async {
        var found: [Entitlement] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, PlanCatalog.product(id: transaction.productID) != nil else { continue }
            var state: SubscriptionState = transaction.revocationDate != nil ? .revoked : .active
            var willRenew = true
            if let status = await transaction.subscriptionStatus {
                state = Self.state(status.state) ?? state
                if case .verified(let renewal) = status.renewalInfo { willRenew = renewal.willAutoRenew }
            }
            found.append(Entitlement(productID: transaction.productID, state: state, expires: transaction.expirationDate, willRenew: willRenew))
        }
        entitlement = EntitlementRules.best(found)

        // Nothing current: find out why, so the plan screen can say so plainly.
        problem = nil
        if entitlement?.isCurrent() != true, let anyProduct = products.values.first,
           let statuses = try? await anyProduct.subscription?.status {
            let states = statuses.compactMap { Self.state($0.state) }
            if states.contains(.inBillingRetry) { problem = .inBillingRetry }
            else if states.contains(.revoked) { problem = .revoked }
            else if states.contains(.expired) { problem = .expired }
        }
    }

    private static func state(_ state: Product.SubscriptionInfo.RenewalState) -> SubscriptionState? {
        switch state {
        case .subscribed: return .active
        case .inGracePeriod: return .inGracePeriod
        case .inBillingRetryPeriod: return .inBillingRetry
        case .expired: return .expired
        case .revoked: return .revoked
        default: return nil
        }
    }

    func purchase(_ plan: PlanProduct) async {
        guard let product = products[plan.id] else {
            message = "This plan can't be bought right now. Check your connection and try again."
            return
        }
        busy = true; defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refresh()
                    message = nil
                } else {
                    message = "The App Store could not confirm this purchase. You have not been given access. Try Restore Purchases."
                }
            case .pending:
                message = "Your purchase is waiting for approval. Access starts as soon as it is approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase did not go through. You have not been charged by this app. \(error.localizedDescription)"
        }
    }

    func restore() async {
        busy = true; defer { busy = false }
        do {
            try await AppStore.sync()
            await refresh()
            message = entitlement?.isCurrent() == true ? "Your subscription was restored." : "No active subscription was found for this Apple Account."
        } catch {
            message = "Could not reach the App Store to restore purchases. Try again."
        }
    }

    func access(to kind: ConsoleKind) -> AccessDecision {
        EntitlementRules.access(to: SourcePlatform(kind), entitlement: entitlement, selectedPlatform: selectedPlatform)
    }

    /// Price as the store reports it for this person's country; the owner's US price until then.
    func priceText(_ plan: PlanProduct) -> String { products[plan.id]?.displayPrice ?? plan.referencePriceText }
    var pricesAreFromStore: Bool { loadState == .loaded }
}
