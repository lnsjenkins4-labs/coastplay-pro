import SwiftUI
import RGPCore

/// Lets a person change which button sends what, with a live check. Applies to the physical
/// controller; the on-screen controls are already labelled and are left alone.
struct RemapView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var controllers: GameControllerProvider
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    Text("LIVE CHECK").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    if controllers.active == nil {
                        Text("Connect a controller to try your layout. Your layout is saved and comes back when the controller reconnects.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        let pressed = controllers.state.buttons
                        let sent = model.buttonMapping.apply(controllers.state).buttons
                        line("You press", names(pressed))
                        line("Console receives", names(sent), highlight: pressed != sent)
                    }
                }
                .accessibilityIdentifier("remapLiveCheck")
                Card {
                    Text("BUTTONS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(ButtonMapping.remappable, id: \.0.rawValue) { button, name in
                        HStack {
                            Text(name).font(.subheadline)
                            Spacer()
                            Text("sends").font(.caption).foregroundStyle(.secondary)
                            Picker(name, selection: Binding(get: { model.buttonMapping.target(for: button).rawValue },
                                                            set: { model.buttonMapping.set(button, to: ControllerButtons(rawValue: $0)) })) {
                                ForEach(ButtonMapping.remappable, id: \.0.rawValue) { target, targetName in
                                    Text(targetName).tag(target.rawValue)
                                }
                            }
                            .labelsHidden()
                            .tint(model.buttonMapping.target(for: button) == button ? Theme.accent : Theme.demo)
                        }
                        .accessibilityIdentifier("remap-\(name)")
                    }
                    let duplicates = model.buttonMapping.duplicateTargets
                    if !duplicates.isEmpty {
                        Text("More than one button now sends \(names(ControllerButtons(duplicates))). That's allowed, but something else may no longer be reachable.")
                            .font(.footnote).foregroundStyle(Theme.demo)
                    }
                }
                Card {
                    Text("STICKS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Toggle("Swap left and right sticks", isOn: $model.buttonMapping.swapSticks)
                    Toggle("Invert left stick up/down", isOn: $model.buttonMapping.invertLeftY)
                    Toggle("Invert right stick up/down", isOn: $model.buttonMapping.invertRightY)
                }
                Card {
                    Button("Reset to default layout", role: .destructive) { confirmReset = true }
                        .disabled(model.buttonMapping.isDefault)
                        .accessibilityIdentifier("remapReset")
                    Text("Your layout is saved on this device and used every time you play. If you also remap buttons in the iPhone's own Settings → General → Game Controller, that change happens first and this one is applied on top, so use one or the other.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("L2 and R2 (the triggers) and the PS button can't be remapped here yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Button layout")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset the button layout?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset to default", role: .destructive) { model.buttonMapping = .default }
        }
    }

    private func names(_ buttons: ControllerButtons) -> String {
        let list = ControllerButtons.labelled.filter { buttons.contains($0.0) }.map(\.1)
        return list.isEmpty ? "nothing" : list.joined(separator: ", ")
    }

    private func line(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(highlight ? Theme.accent : .white)
        }
    }
}

private extension ControllerButtons {
    init(_ list: [ControllerButtons]) { self = list.reduce(into: []) { $0.formUnion($1) } }
}
