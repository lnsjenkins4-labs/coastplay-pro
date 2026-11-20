import SwiftUI

/// Our service promise and refund policy, in plain language. DRAFT wording supplied by the
/// owner on 2026-11-16; it has not been reviewed by a lawyer and no payment system exists yet.
/// The same text lives in docs/SERVICE_AND_REFUND_POLICY.md — change both together.
struct PolicyView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if AppModel.isPrivatePrototype {
                    Card {
                        Label("Draft — not final", systemImage: "pencil.and.outline").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.demo)
                        Text("This wording is being prepared for launch. It is shown here for review and is not yet a binding policy.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Card {
                    Text("OUR PROMISE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    point("We tell you the truth about your connection", "If something fails, the app says what failed and why, in plain words. We never show a made-up error, and we never tell you something is fixed when it isn't.")
                    point("We don't promise what no one can", "Remote play depends on your console, your home internet and the network you're on. We can't guarantee it works on every network, and we say so before you buy.")
                    point("Your account stays yours", "This app has no account of its own. You sign in on Sony's own page, and the app never sees your PlayStation password.")
                    point("Your gameplay stays private", "Picture, sound and controller input travel directly between your console and your device. They do not pass through our servers; we don't run any.")
                    point("We're independent", "CoastPlay PRO is not made, endorsed or supported by Sony or Microsoft. You need your own console and your own games.")
                }
                Card {
                    Text("WHAT YOU NEED FOR IT TO WORK").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    check("A PlayStation 5 you own, switched on or in rest mode, with Remote Play turned on")
                    check("The PlayStation connected to your home network (a network cable is best)")
                    check("Home internet that meets Sony's suggestion: at least 5 Mbps, 15 Mbps for best results")
                    check("Access to your own router if you want to play on mobile data (see the router guide)")
                    check("No VPN, firewall or network rule blocking the connection on either end")
                    check("A supported device and a controller connected to it")
                }
                Card {
                    Text("REFUNDS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    point("Purchases go through Apple", "Plans are bought with your Apple Account, so Apple handles every refund. We cannot issue one ourselves.")
                    point("How to ask", "Go to reportaproblem.apple.com, sign in, choose the CoastPlay PRO purchase and pick Request a refund. Apple decides each request.")
                    point("If it would not work for you", "Tell us first (Help → Create a support report) and we will try to fix it. If you met everything in the list above and it still would not work, say so in your refund request.")
                    point("Cancelling", "You can cancel any time in your Apple Account's subscriptions. Access continues until the end of the period you paid for.")
                    Text("Nothing here takes away rights you have under the law where you live.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Our promise & refunds")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func point(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func check(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle").font(.subheadline).fixedSize(horizontal: false, vertical: true)
    }
}
