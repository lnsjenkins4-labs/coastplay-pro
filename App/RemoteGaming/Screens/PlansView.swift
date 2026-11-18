import SwiftUI
import StoreKit
import RGPCore

/// The plan screen: two tiers, monthly or yearly, what each includes today, restore, and the
/// person's current status. Platform names shown are only the ones that really work today.
struct PlansView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: StoreManager
    @State private var interval = BillingInterval.annual
    @Environment(\.openURL) private var openURL

    private let availability = PlatformAvailability.current

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                status
                Picker("Billing", selection: $interval) {
                    ForEach(BillingInterval.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("intervalPicker")

                planCard(.single)
                planCard(.allAccess)

                if let message = store.message {
                    Card { Text(message).font(.subheadline) }
                }
                Card {
                    Button { Task { await store.restore() } } label: { Label("Restore Purchases", systemImage: "arrow.clockwise") }
                        .disabled(store.busy)
                        .accessibilityIdentifier("restoreButton")
                    if store.entitlement != nil {
                        Button { Task { await showManage() } } label: { Label("Manage or cancel subscription", systemImage: "gearshape") }
                    }
                    Text("Payment is charged to your Apple Account at confirmation. The subscription renews automatically at the price shown unless it is cancelled at least 24 hours before the end of the current period. You can manage or cancel it in your Apple Account settings. Refunds for purchases made here are handled by Apple.")
                        .font(.caption).foregroundStyle(.secondary)
                    NavigationLink { PolicyView() } label: { Text("Our promise and refund policy").font(.caption) }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
        .task { if store.loadState != .loaded { await store.loadProducts() }; await store.refresh() }
    }

    // MARK: Current status

    @ViewBuilder private var status: some View {
        if let entitlement = store.entitlement, entitlement.isCurrent(), let product = entitlement.product {
            Card {
                Label("\(product.tier.displayName), \(product.interval.displayName.lowercased())", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(Theme.good)
                let platforms = EntitlementRules.includedPlatforms(tier: product.tier, selectedPlatform: store.selectedPlatform)
                Text("Includes: \(ListFormatter.localizedString(byJoining: platforms.map(\.displayName)))").font(.subheadline)
                if entitlement.state == .inGracePeriod {
                    Text("Your last payment didn't go through. You still have access while the App Store retries. Check your payment method in your Apple Account.")
                        .font(.footnote).foregroundStyle(Theme.demo)
                } else if let expires = entitlement.expires {
                    Text(entitlement.willRenew ? "Renews \(expires.formatted(date: .abbreviated, time: .omitted))."
                                               : "Cancelled. Access continues until \(expires.formatted(date: .abbreviated, time: .omitted)).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if product.tier == .single, availability.available.count > 1 { platformChoice }
            }
            .accessibilityIdentifier("currentPlanCard")
        } else if let problem = store.problem {
            Card {
                Label(problemTitle(problem), systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(Theme.demo)
                Text(problemText(problem)).font(.subheadline).foregroundStyle(.secondary)
            }
        } else if !model.billingEnforced {
            Card {
                Label("Plans are not switched on yet", systemImage: "info.circle").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.demo)
                Text("This test build lets you play without a plan. Prices below are the planned prices; nothing can be bought until the plans exist in the App Store.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Only shown when more than one platform is really available.
    private var platformChoice: some View {
        Picker("Your platform", selection: Binding(get: { EntitlementRules.effectiveSelection(store.selectedPlatform) ?? availability.available[0] },
                                                   set: { store.selectedPlatform = $0 })) {
            ForEach(availability.available) { Text($0.displayName).tag($0) }
        }
    }

    private func problemTitle(_ state: SubscriptionState) -> String {
        switch state {
        case .inBillingRetry: return "Payment problem"
        case .revoked: return "Subscription refunded"
        default: return "Subscription ended"
        }
    }

    private func problemText(_ state: SubscriptionState) -> String {
        switch state {
        case .inBillingRetry: return "The App Store couldn't charge your payment method, so access is paused. Update your payment method in your Apple Account and access returns by itself."
        case .revoked: return "This subscription was refunded by Apple, so access has ended. You can subscribe again below."
        default: return "Your subscription has ended. Your consoles and settings are still saved. Subscribe again below to keep playing."
        }
    }

    // MARK: Plan cards

    private func planCard(_ tier: PlanTier) -> some View {
        let plan = PlanCatalog.product(tier, interval)
        let current = store.entitlement.flatMap { $0.isCurrent() ? $0.product : nil }
        let change = current.map { EntitlementRules.change(from: $0, to: plan) }
        return Card {
            HStack(alignment: .firstTextBaseline) {
                Text(tier.displayName).font(.title3.weight(.semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(store.priceText(plan)).font(.title3.weight(.bold))
                    Text(interval.perText).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(EntitlementRules.accessSummary(tier: tier)).font(.subheadline)
            Text("Register as many of your own consoles as you like. Play on any device this app supports.")
                .font(.footnote).foregroundStyle(.secondary)
            if interval == .annual {
                let monthly = PlanCatalog.product(tier, .monthly)
                Text("Twelve monthly payments would be \(twelve(monthly)).").font(.footnote).foregroundStyle(.secondary)
            }
            Button { Task { await store.purchase(plan) } } label: {
                Text(buttonTitle(change)).frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.busy || change == PlanChange.none || store.products[plan.id] == nil)
            .accessibilityIdentifier("buy-\(plan.id)")
            if store.products[plan.id] == nil {
                Text(store.loadState == .loading ? "Loading from the App Store…" : "Not available to buy yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if change == .downgrade {
                Text("Takes effect at your next renewal. You keep \(current?.tier.displayName ?? "your plan") until then.").font(.caption).foregroundStyle(.secondary)
            } else if change == .upgrade {
                Text("Starts now. Apple refunds the unused part of your current plan.").font(.caption).foregroundStyle(.secondary)
            } else if change == .crossgrade {
                Text("Changes how often you're billed. Your access stays the same.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func twelve(_ monthly: PlanProduct) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = "USD"; f.locale = Locale(identifier: "en_US")
        return f.string(from: (monthly.referencePriceUSD * 12) as NSDecimalNumber) ?? ""
    }

    private func buttonTitle(_ change: PlanChange?) -> String {
        switch change {
        case .upgrade?: return "Upgrade"
        case .downgrade?: return "Switch at next renewal"
        case .crossgrade?: return "Switch billing"
        case PlanChange.none?: return "Your current plan"
        case nil: return "Subscribe"
        }
    }

    private func showManage() async {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            try? await AppStore.showManageSubscriptions(in: scene)
            await store.refresh()
        }
    }
}
