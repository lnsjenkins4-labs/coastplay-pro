import SwiftUI
import RGPCore

/// Step-by-step guide for letting the console be reached from mobile data by forwarding its
/// Remote Play ports on the home router. Optional: only needed when the away-from-home test fails.
/// Only routers we have actually set up and tested get exact, illustrated steps.
struct RouterGuideView: View {
    @EnvironmentObject var model: AppModel

    enum Router: String, CaseIterable, Identifiable {
        case attBGW320 = "AT&T BGW320 (tested)"
        case other = "A different router"
        var id: String { rawValue }
    }
    @State private var router: Router = .attBGW320

    /// The saved PlayStation's address on the home network, to help pick the right device.
    private var consoleLine: String? {
        guard let console = model.consoles.first(where: { $0.kind == .ps5 && !$0.isDemo }),
              let address = console.lastKnownAddress, NetworkAddress.isLocal(address) else { return nil }
        return "\(console.name) — address \(address)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                intro
                Picker("Your router", selection: $router) {
                    ForEach(Router.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("routerPicker")

                switch router {
                case .attBGW320: attSteps
                case .other: genericSteps
                }
                aiHelper
                finish
                safety
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Router setup")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Shared pieces

    private var intro: some View {
        Card {
            Text("Play on mobile data").font(.title3.weight(.semibold))
            Text("Most Wi-Fi works without any of this. Mobile data often can't reach your console directly. A one-time change on your home router fixes that. It takes about ten minutes, on a computer or phone connected to your home Wi-Fi.")
                .font(.subheadline).foregroundStyle(.secondary)
            PathDiagram()
            Text("You only need this if “Test away from home” fails on mobile data.").font(.footnote).foregroundStyle(Theme.demo)
        }
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(number)").font(.headline).frame(width: 28, height: 28)
                    .background(Theme.accent, in: Circle()).foregroundStyle(.white)
                Text(title).font(.headline)
            }
            content()
        }
    }

    /// Our own simple drawings of what to look for and what to type. (The app used to show
    /// screenshots of the router maker's pages; those were someone else's material.)
    private func sketch(_ caption: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.15)))
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 118, alignment: .leading)
            Text(value).font(.system(.caption, design: .monospaced)).padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.3)))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }

    /// The four values to type, laid out as two entries, each with a copy button.
    private var portTable: some View {
        VStack(spacing: 8) {
            PortEntry(name: "PS5RemotePlay", from: "9295", to: "9297", base: "9295", proto: "TCP/UDP")
            PortEntry(name: "PS5Discovery", from: "9302", to: "9302", base: "9302", proto: "UDP")
        }
    }

    /// Text a person can paste into any AI assistant to be walked through their own router.
    private var aiPrompt: String {
        let routerLine = router == .attBGW320
            ? "My router is an AT&T BGW320 gateway."
            : "My router is: (type the brand and model printed on your router's label here)."
        return """
        I need help setting up port forwarding on my home router so I can use PlayStation 5 Remote Play away from home. \(routerLine) Please walk me through it one small step at a time, wait for me to say "done" before the next step, and tell me exactly which menu names to look for on my router model.

        What needs to be set up:
        1. Forward ports 9295 to 9297, both TCP and UDP, to my PlayStation 5.
        2. Forward port 9302, UDP only, to my PlayStation 5.
        Use the same port numbers for external and internal ports.

        Also tell me how to find my PlayStation 5 in the router's device list, and how to give it a fixed (reserved) address if my router supports that, so the setting keeps working.

        Important: do not ask me for my router password, access code or Wi-Fi password. I will type those only into the router's own page.
        """
    }

    private var aiHelper: some View {
        Card {
            Label("Prefer to be talked through it?", systemImage: "sparkles").font(.headline)
            note("If you use an AI assistant (ChatGPT, Claude, Gemini or another), copy this request and paste it there. It will guide you through your own router one step at a time.")
            CopyButton(label: "Copy the request", text: aiPrompt)
            Text("Never paste your router's access code or any password into a chat. Type them only into the router's own page. An assistant can get menu names wrong; if its steps don't match your screen, the port numbers above are what matter.")
                .font(.footnote).foregroundStyle(Theme.demo).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("aiHelperCard")
    }

    private var finish: some View {
        Card {
            Label("Finish in this app", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.good)
            note("1. Open this app once while on your home Wi-Fi. It notes your home's internet address by itself.")
            note("2. Turn Wi-Fi off, then go to Devices → Test away from home.")
            NavigationLink { DevicesShortcut() } label: { Label("Go to the away-from-home test", systemImage: "antenna.radiowaves.left.and.right") }
                .font(.subheadline)
        }
    }

    private var safety: some View {
        Card {
            Text("GOOD TO KNOW").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            note("This makes your console's Remote Play reachable from the internet. It still needs the pairing saved in this app to connect.")
            note("To undo it, go back to the same router page and delete the two entries.")
            note("If your internet provider changes your home's address, just open this app at home again.")
            note("If away play stops working after you move the console between Wi-Fi and a cable, or after the router restarts, the router may be pointing at the console's old connection. Open the router page, delete the two entries, and add them again choosing your PlayStation.")
        }
    }

    // MARK: AT&T BGW320 (set up and tested by us on 16 Nov 2026)

    private var attSteps: some View {
        Group {
            step(1, "Find the Device Access Code") {
                note("It's printed on a label on the side or bottom of the AT&T gateway. It is not your Wi-Fi password.")
                sketch("A drawing of the label. Yours has its own code.") {
                    Text("Wi-Fi Network Name   • • • • • •").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Text("Wi-Fi Password       • • • • • •").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Label("Device Access Code   ← this one", systemImage: "arrow.right.circle.fill").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                }
            }
            step(2, "Open the gateway's page") {
                note("On a device connected to your home Wi-Fi, open a web browser and go to:")
                CopyLine(text: "http://192.168.1.254")
                note("Choose Firewall, then NAT/Gaming. When asked, type the Device Access Code and tap Continue.")
            }
            step(3, "Add two custom services") {
                note("Tap Custom Services at the bottom. Fill in the boxes with the first entry below and tap Add. Then do the same with the second entry.")
                sketch("A drawing of the form, filled in with the first entry.") {
                    field("Service Name", "PS5RemotePlay")
                    field("Global Port Range", "9295  -  9297")
                    field("Base Host Port", "9295")
                    field("Protocol", "TCP/UDP")
                    Text("Add").font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.8), in: RoundedRectangle(cornerRadius: 5))
                }
                portTable
                note("Then tap Return to NAT/Gaming.")
            }
            step(4, "Point them at your PlayStation") {
                note("On NAT/Gaming, choose PS5RemotePlay under Service, choose your PlayStation under Needed by Device, and tap Add. Repeat with PS5Discovery.")
                if let consoleLine {
                    Label("Your console: \(consoleLine)", systemImage: "gamecontroller.fill").font(.footnote).foregroundStyle(Theme.accent)
                }
                note("If two PlayStations are listed, the gateway's Home Network → Devices page shows which one has that address.")
                sketch("When it's done, both entries are listed against your PlayStation and the page says “Changes saved”.") {
                    Label("PS5RemotePlay  →  your PlayStation", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.good)
                    Label("PS5Discovery  →  your PlayStation", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Theme.good)
                }
            }
        }
    }

    // MARK: Any other router (general steps; not tested by us on your model)

    private var genericSteps: some View {
        Group {
            Card {
                Label("We haven't tested your router model", systemImage: "info.circle").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.demo)
                note("The steps below are the general pattern. The names of menus differ between routers; your router's manual or support page will show the exact screens.")
            }
            step(1, "Find the router's sign-in details") {
                note("Look for a label on the back or bottom of the router. It usually shows the router's address (often 192.168.0.1, 192.168.1.1 or 192.168.1.254) and an admin password or access code. This is not your Wi-Fi password.")
                RouterLabelDiagram()
            }
            step(2, "Open the router's page") {
                note("On a device connected to your home Wi-Fi, open a web browser, type the router's address, and sign in.")
            }
            step(3, "Find port forwarding") {
                note("It may be called Port Forwarding, NAT, Gaming, Virtual Server, Applications or Firewall.")
            }
            step(4, "Add these and point them at your PlayStation") {
                portTable
                if let consoleLine {
                    Label("Your console: \(consoleLine)", systemImage: "gamecontroller.fill").font(.footnote).foregroundStyle(Theme.accent)
                }
                note("Where the router asks for an internal or device address, use your PlayStation's address. Save the changes.")
            }
        }
    }
}

/// One port-forward entry with its values and a copy button for the name.
private struct PortEntry: View {
    let name: String, from: String, to: String, base: String, proto: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Service Name", name)
            row("Port range", from == to ? from : "\(from) to \(to)")
            row("Base / internal port", base)
            row("Protocol", proto)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).font(.subheadline.monospaced().weight(.semibold)).textSelection(.enabled)
        }
    }
}

private struct CopyButton: View {
    let label: String, text: String
    @State private var copied = false
    var body: some View {
        Button { UIPasteboard.general.string = text; copied = true } label: {
            Label(copied ? "Copied — now paste it into your assistant" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("copyAIPrompt")
    }
}

private struct CopyLine: View {
    let text: String
    @State private var copied = false
    var body: some View {
        HStack {
            Text(text).font(.subheadline.monospaced().weight(.semibold)).textSelection(.enabled)
            Spacer()
            Button(copied ? "Copied" : "Copy") { UIPasteboard.general.string = text; copied = true }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Phone → internet → home router → console.
private struct PathDiagram: View {
    var body: some View {
        HStack(spacing: 6) {
            node("iphone", "This device")
            arrow
            node("globe", "Internet")
            arrow
            node("wifi.router", "Your router")
            arrow
            node("gamecontroller.fill", "Console")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityLabel("This device connects through the internet to your router, which passes it to the console.")
    }
    private var arrow: some View { Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary) }
    private func node(_ icon: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A drawn router with its label highlighted (an illustration, not a photo of a real model).
private struct RouterLabelDiagram: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.12)).frame(width: 84, height: 110)
                RoundedRectangle(cornerRadius: 4).fill(Theme.demo.opacity(0.9)).frame(width: 60, height: 34).padding(.bottom, 10)
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { _ in Capsule().fill(.black.opacity(0.55)).frame(width: 44, height: 3) }
                        }
                        .padding(.bottom, 20)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("The label", systemImage: "arrow.left").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.demo)
                Text("Router address\nAdmin password or access code").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Illustration of a router with its label highlighted.")
    }
}

/// Small landing screen so the guide can send people to the test without knowing which console.
private struct DevicesShortcut: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let console = model.consoles.first(where: { $0.kind == .ps5 && !$0.isDemo }) {
            AwayTestView(console: console)
        } else {
            Text("Pair a console first, in Devices.").foregroundStyle(.secondary).padding()
        }
    }
}
