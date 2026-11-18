import XCTest
@testable import RGPCore
import RGPMirror

final class PlanCatalogTests: XCTestCase {
    func testTheFourExactPrices() {
        XCTAssertEqual(PlanCatalog.all.count, 4)
        XCTAssertEqual(PlanCatalog.singleAnnual.referencePriceUSD, Decimal(string: "20.00"))   // exactly $20, not $19.99
        XCTAssertEqual(PlanCatalog.singleAnnual.referencePriceText, "$20.00")
        XCTAssertEqual(PlanCatalog.singleMonthly.referencePriceText, "$4.99")
        XCTAssertEqual(PlanCatalog.allAnnual.referencePriceText, "$29.99")
        XCTAssertEqual(PlanCatalog.allMonthly.referencePriceText, "$5.99")
        XCTAssertEqual(Set(PlanCatalog.all.map(\.id)).count, 4)
    }

    func testAllAccessRanksAboveSingle() {
        XCTAssertLessThan(PlanTier.allAccess.groupLevel, PlanTier.single.groupLevel)
    }

    func testPlanChanges() {
        XCTAssertEqual(EntitlementRules.change(from: PlanCatalog.singleMonthly, to: PlanCatalog.allMonthly), .upgrade)
        XCTAssertEqual(EntitlementRules.change(from: PlanCatalog.singleAnnual, to: PlanCatalog.allMonthly), .upgrade)
        XCTAssertEqual(EntitlementRules.change(from: PlanCatalog.allAnnual, to: PlanCatalog.singleAnnual), .downgrade)
        XCTAssertEqual(EntitlementRules.change(from: PlanCatalog.singleMonthly, to: PlanCatalog.singleAnnual), .crossgrade)
        XCTAssertEqual(EntitlementRules.change(from: PlanCatalog.allAnnual, to: PlanCatalog.allMonthly), .crossgrade)
        XCTAssertEqual(EntitlementRules.change(from: PlanCatalog.allAnnual, to: PlanCatalog.allAnnual), .none)
    }
}

final class EntitlementRuleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var later: Date { now.addingTimeInterval(86_400 * 20) }
    var earlier: Date { now.addingTimeInterval(-86_400) }
    let ps5Only = PlatformAvailability(available: [.ps5])
    let ps5AndPC = PlatformAvailability(available: [.ps5, .pc])

    func active(_ p: PlanProduct, willRenew: Bool = true) -> Entitlement {
        Entitlement(productID: p.id, state: .active, expires: later, willRenew: willRenew)
    }

    func testNoSubscriptionNeedsPlan() {
        XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: nil, selectedPlatform: nil, availability: ps5Only, now: now), .needsPlan)
    }

    func testMonthlyAndAnnualGrantTheSameAccess() {
        for product in [PlanCatalog.singleMonthly, PlanCatalog.singleAnnual, PlanCatalog.allMonthly, PlanCatalog.allAnnual] {
            XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: active(product), selectedPlatform: .ps5, availability: ps5Only, now: now), .allowed, product.id)
        }
    }

    func testSinglePlatformWithOneAvailablePlatformNeedsNoChoice() {
        XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: active(PlanCatalog.singleAnnual), selectedPlatform: nil, availability: ps5Only, now: now), .allowed)
    }

    func testSinglePlatformMustChooseWhenSeveralAreAvailable() {
        let e = active(PlanCatalog.singleAnnual)
        XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: e, selectedPlatform: nil, availability: ps5AndPC, now: now), .needsPlatformChoice)
        XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: e, selectedPlatform: .ps5, availability: ps5AndPC, now: now), .allowed)
        XCTAssertEqual(EntitlementRules.access(to: .pc, entitlement: e, selectedPlatform: .ps5, availability: ps5AndPC, now: now), .notIncluded(selected: .ps5))
    }

    func testAllAccessPicksUpNewlyEnabledPlatformsWithoutAnyChange() {
        let e = active(PlanCatalog.allMonthly)
        XCTAssertEqual(EntitlementRules.access(to: .pc, entitlement: e, selectedPlatform: nil, availability: ps5Only, now: now), .notAvailableYet)
        XCTAssertEqual(EntitlementRules.access(to: .pc, entitlement: e, selectedPlatform: nil, availability: ps5AndPC, now: now), .allowed)
        XCTAssertEqual(EntitlementRules.includedPlatforms(tier: .allAccess, selectedPlatform: nil, availability: ps5AndPC), [.ps5, .pc])
    }

    func testUnsupportedPlatformIsNeverSoldAsAvailable() {
        XCTAssertEqual(EntitlementRules.access(to: .xbox, entitlement: active(PlanCatalog.allAnnual), selectedPlatform: nil, availability: ps5AndPC, now: now), .notAvailableYet)
        XCTAssertFalse(PlatformAvailability.current.isAvailable(.pc), "PC must not be listed until it is verified on real hardware")
        XCTAssertEqual(PlatformAvailability.current.available, [.ps5])
    }

    func testCancelledKeepsAccessUntilThePaidPeriodEnds() {
        let cancelled = active(PlanCatalog.singleMonthly, willRenew: false)
        XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: cancelled, selectedPlatform: .ps5, availability: ps5Only, now: now), .allowed)
        let lapsed = Entitlement(productID: PlanCatalog.singleMonthly.id, state: .active, expires: earlier, willRenew: false)
        XCTAssertEqual(EntitlementRules.access(to: .ps5, entitlement: lapsed, selectedPlatform: .ps5, availability: ps5Only, now: now), .needsPlan)
    }

    func testExpiredRefundedAndBillingRetryLoseAccessButGracePeriodKeepsIt() {
        func decision(_ state: SubscriptionState) -> AccessDecision {
            EntitlementRules.access(to: .ps5, entitlement: Entitlement(productID: PlanCatalog.allAnnual.id, state: state, expires: earlier),
                                    selectedPlatform: nil, availability: ps5Only, now: now)
        }
        XCTAssertEqual(decision(.expired), .needsPlan)
        XCTAssertEqual(decision(.revoked), .needsPlan)
        XCTAssertEqual(decision(.inBillingRetry), .needsPlan)
        XCTAssertEqual(decision(.inGracePeriod), .allowed)
    }

    func testRestorePicksTheBestRecord() {
        let old = Entitlement(productID: PlanCatalog.allAnnual.id, state: .expired, expires: earlier)
        let single = active(PlanCatalog.singleAnnual)
        let all = active(PlanCatalog.allMonthly)
        XCTAssertEqual(EntitlementRules.best([old, single], now: now), single)
        XCTAssertEqual(EntitlementRules.best([single, all, old], now: now), all)
        XCTAssertNil(EntitlementRules.best([], now: now))
        XCTAssertNil(EntitlementRules.best([Entitlement(productID: "someone.elses.product", state: .active)], now: now))
    }

    func testAccessIsAboutTheSourceNotTheNumberOfConsoles() {
        // Two registered PS5 consoles are the same platform: both are covered by Single Platform.
        let e = active(PlanCatalog.singleAnnual)
        for kind in [ConsoleKind.ps5, ConsoleKind.ps5] {
            XCTAssertEqual(EntitlementRules.access(to: SourcePlatform(kind), entitlement: e, selectedPlatform: .ps5, availability: ps5AndPC, now: now), .allowed)
        }
        XCTAssertEqual(SourcePlatform(.computer), .pc)
    }

    func testPlanSummariesOnlyNameAvailablePlatforms() {
        XCTAssertFalse(EntitlementRules.accessSummary(tier: .allAccess, availability: ps5Only).contains("PC"))
        XCTAssertTrue(EntitlementRules.accessSummary(tier: .allAccess, availability: ps5AndPC).contains("PC"))
        XCTAssertTrue(EntitlementRules.accessSummary(tier: .single, availability: ps5Only).contains("PlayStation 5"))
    }
}

final class ButtonMappingTests: XCTestCase {
    func testDefaultChangesNothing() {
        var s = ControllerState(); s.buttons = [.cross, .l1]; s.leftX = 0.5; s.rightY = -0.25
        XCTAssertEqual(ButtonMapping.default.apply(s), s)
        XCTAssertTrue(ButtonMapping().isDefault)
    }

    func testSwapTwoButtons() {
        var m = ButtonMapping()
        m.set(.cross, to: .circle); m.set(.circle, to: .cross)
        var s = ControllerState(); s.buttons = [.cross]
        XCTAssertEqual(m.apply(s).buttons, [.circle])
        s.buttons = [.circle, .square]
        XCTAssertEqual(m.apply(s).buttons, [.cross, .square])
        XCTAssertTrue(m.duplicateTargets.isEmpty)
    }

    func testSettingAButtonBackToItselfClearsTheEntryAndResetWorks() {
        var m = ButtonMapping()
        m.set(.l1, to: .r1)
        XCTAssertFalse(m.isDefault)
        XCTAssertEqual(m.duplicateTargets, [.r1])
        m.set(.l1, to: .l1)
        XCTAssertTrue(m.isDefault)
    }

    func testSticksSwapAndInvert() {
        var m = ButtonMapping(); m.swapSticks = true; m.invertRightY = true
        var s = ControllerState(); s.leftX = 0.3; s.leftY = 0.6; s.rightX = -0.2; s.rightY = 0.1
        let out = m.apply(s)
        XCTAssertEqual(out.leftX, -0.2); XCTAssertEqual(out.leftY, 0.1)
        XCTAssertEqual(out.rightX, 0.3); XCTAssertEqual(out.rightY, -0.6)
    }

    func testSurvivesSavingAndLoading() throws {
        var m = ButtonMapping(); m.set(.triangle, to: .square); m.invertLeftY = true
        let data = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(ButtonMapping.self, from: data), m)
    }

    func testPSButtonIsNotOffered() {
        XCTAssertFalse(ButtonMapping.remappable.contains { $0.0 == .ps })
    }
}

final class GameKeysTests: XCTestCase {
    func testNeutralControllerPressesNothing() {
        XCTAssertEqual(GameKeys.state(for: .neutral), GameKeyState())
    }

    func testLeftStickBecomesWASD() {
        var c = ControllerState(); c.leftY = 1
        XCTAssertEqual(GameKeys.state(for: c).keys, [GameKeys.Key.w])
        c.leftY = -0.8; c.leftX = 0.9
        XCTAssertEqual(GameKeys.state(for: c).keys, [GameKeys.Key.s, GameKeys.Key.d])
        c.leftY = 0.2; c.leftX = -0.2          // small pushes are ignored
        XCTAssertTrue(GameKeys.state(for: c).keys.isEmpty)
    }

    func testTriggersAreMouseButtonsAndRightStickLooks() {
        var c = ControllerState(); c.r2 = 1; c.l2 = 0.1; c.rightX = 0.5; c.rightY = 0.05
        let s = GameKeys.state(for: c)
        XCTAssertTrue(s.leftMouse); XCTAssertFalse(s.rightMouse)
        XCTAssertEqual(s.lookX, 0.5); XCTAssertEqual(s.lookY, 0)
    }

    func testButtonsAndLegendCoverEveryControl() {
        var c = ControllerState(); c.buttons = [.cross, .options, .dpadUp]
        XCTAssertEqual(GameKeys.state(for: c).keys, [GameKeys.Key.space, GameKeys.Key.escape, GameKeys.Key.up])
        XCTAssertEqual(GameKeys.legend.count, 16)
    }
}

final class ControllerSupportTests: XCTestCase {
    func testOnlyTheDualSenseIsCalledTested() {
        XCTAssertEqual(ControllerSupport.status(category: "DualSense", name: "DualSense Wireless Controller").title, "Tested with a real console")
        for (category, name) in [("Xbox One", "Xbox Wireless Controller"), ("DualShock 4", "DUALSHOCK 4 Wireless Controller"),
                                 ("Switch Pro Controller", "Pro Controller"), ("MFi", "Backbone One")] {
            guard case .expected = ControllerSupport.status(category: category, name: name) else { return XCTFail("\(name) must not be called tested") }
        }
        XCTAssertEqual(ControllerSupport.status(category: "", name: "Mystery Pad"), .unknown)
    }
}
