import SwiftUI
import RGPCore

struct ControllerSetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var controllers: GameControllerProvider
    @State private var sawMove = false
    @State private var sawConfirm = false
    @State private var sawBack = false
    @State private var sawHome = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.demoMode { DemoBanner() }
                status
                Card {
                    NavigationLink { RemapView() } label: {
                        VStack(alignment: .leading) {
                            Label("Change the button layout", systemImage: "arrow.left.arrow.right").font(.subheadline.weight(.semibold))
                            Text(model.buttonMapping.isDefault ? "Using the default layout." : "You're using your own layout.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("remapLink")
                }
                if controllers.active != nil { quickCheck; tester }
                features
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Controller")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var status: some View {
        Card {
            if let active = controllers.active {
                Label(active.name, systemImage: "gamecontroller.fill").font(.headline).foregroundStyle(Theme.good)
                Text(active.isExtendedLayout ? "Connected. Full layout detected." : "Connected, but this controller lacks sticks or triggers, so some games will not be playable.")
                    .font(.subheadline)
                if !active.category.isEmpty { Text("Type: \(active.category)").font(.footnote).foregroundStyle(.secondary) }
                let support = active.support
                Label(support.title, systemImage: { if case .tested = support { return "checkmark.seal.fill" } else { return "questionmark.circle" } }())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle({ if case .tested = support { return Theme.good } else { return Theme.demo } }())
                Text(support.note).font(.footnote).foregroundStyle(.secondary)
                if controllers.controllers.count > 1 {
                    Text("\(controllers.controllers.count) controllers connected. Only the first one is used for now.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Label("No controller connected", systemImage: "gamecontroller").font(.headline).foregroundStyle(Theme.bad)
                Text("Pair a controller in the device's Bluetooth settings. DualSense: hold Create + PS until the light bar flashes, then pick it in Settings → Bluetooth.")
                    .font(.subheadline)
                Text("This screen updates automatically when a controller connects or disconnects.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    /// Four things worth confirming before a first game. Each ticks itself when the app sees it.
    private var quickCheck: some View {
        Card {
            Text("QUICK CHECK").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            check(sawMove, "Move the D-pad or left stick")
            check(sawConfirm, "Press Cross (confirm)")
            check(sawBack, "Press Circle (back)")
            check(sawHome, "Press the PS button")
            if !sawHome {
                Text("If the PS button never ticks, iOS is keeping it for itself. That's normal: use the PS button on screen while playing.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("To leave a game, tap Disconnect at the top right of the player. This check shows what the app reads from the controller; the console is confirmed during your first game.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onChange(of: controllers.state) { _, s in
            if s.buttons.contains(.dpadUp) || s.buttons.contains(.dpadDown) || s.buttons.contains(.dpadLeft) || s.buttons.contains(.dpadRight)
                || abs(s.leftX) > 0.5 || abs(s.leftY) > 0.5 { sawMove = true }
            if s.buttons.contains(.cross) { sawConfirm = true }
            if s.buttons.contains(.circle) { sawBack = true }
            if s.buttons.contains(.ps) { sawHome = true }
        }
    }

    private func check(_ done: Bool, _ text: String) -> some View {
        Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
            .font(.subheadline).foregroundStyle(done ? Theme.good : .primary)
    }

    private var tester: some View {
        Card {
            Text("BUTTON & STICK TEST").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text("Press buttons and move the sticks. This shows what the app reads from the controller.").font(.footnote).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(ControllerButtons.labelled, id: \.1) { button, name in
                    let pressed = controllers.state.buttons.contains(button)
                    Text(name).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(pressed ? Theme.accent : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            HStack(spacing: 24) {
                StickView(title: "Left stick", x: controllers.state.leftX, y: controllers.state.leftY)
                StickView(title: "Right stick", x: controllers.state.rightX, y: controllers.state.rightY)
            }
            .frame(maxWidth: .infinity)
            ProgressView(value: Double(controllers.state.l2)) { Text("L2").font(.caption) }
            ProgressView(value: Double(controllers.state.r2)) { Text("R2").font(.caption) }
        }
    }

    private var features: some View {
        Card {
            Text("FEATURE SUPPORT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            ForEach(ControllerFeature.all) { feature in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Image(systemName: feature.support == .supported ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(feature.support == .supported ? Theme.good : .secondary)
                        Text(feature.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(feature.support.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(feature.note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StickView: View {
    let title: String
    let x: Float
    let y: Float
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
                Circle().fill(Theme.accent).frame(width: 18, height: 18)
                    .offset(x: CGFloat(x) * 36, y: CGFloat(-y) * 36)
            }
            .frame(width: 90, height: 90)
            Text(title).font(.caption)
            Text(String(format: "%+.2f, %+.2f", x, y)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
