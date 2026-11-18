import SwiftUI
import WebKit
import RGPCore

/// Shows the console vendor's own sign-in page. The page is the vendor's; this app does not read
/// what is typed into it and stores no password. Cookies are not kept after the sheet closes.
///
/// A web view is used instead of the system sign-in sheet because the vendor's flow finishes on
/// the vendor's own web address, which the system sheet cannot hand back to an app.
struct SignInSheet: View {
    let signIn: AccountSignIn
    let onFinished: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var working = false
    @State private var failure: SessionFailure?
    @State private var host = ""
    /// Passkeys do not work inside an app's web view, so offer the same sign-in in Safari.
    @State private var useSafari = false
    /// The first screen asks how the person signs in, because a passkey cannot be used on the
    /// in-app page and Sony's fallback there is a QR code that needs a second device.
    @State private var chosen = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var pasteProblem: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // One line only, so Sony's page keeps as much room as possible above the keyboard.
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                    Text(host.isEmpty ? "\(signIn.providerName)'s own sign-in page" : host).lineLimit(1)
                    Spacer()
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Theme.card)

                if let failure {
                    ScrollView { FailureCard(failure: failure).padding(16) }
                    Button("Try again") { self.failure = nil; url = signIn.makeSignInURL() }.buttonStyle(.borderedProminent).padding()
                } else if working {
                    Spacer(); ProgressView("Finishing sign-in…"); Spacer()
                } else if !chosen {
                    chooser
                } else if useSafari, let url {
                    safariSteps(url)
                } else if let url {
                    VendorWebView(url: url, redirectPrefix: signIn.redirectPrefix, host: $host) { redirect in
                        working = true
                        Task {
                            do {
                                let stored = try await signIn.complete(redirect: redirect)
                                onFinished(stored)
                                dismiss()
                            } catch let error as SessionFailure {
                                failure = error
                            } catch {
                                failure = SessionFailure(code: .unknown, title: "Sign-in didn't finish",
                                                         message: "The sign-in could not be completed. Check your internet connection.",
                                                         recovery: ["Try again."])
                            }
                            working = false
                        }
                    }
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("\(signIn.providerName) sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if chosen, !useSafari, !working, failure == nil {
                    // For when Sony's page asks for a passkey or shows a QR code.
                    ToolbarItem(placement: .primaryAction) {
                        Button("Use Safari") { useSafari = true }.accessibilityIdentifier("useSafariButton")
                    }
                }
            }
            .onAppear { if url == nil { url = signIn.makeSignInURL() } }
        }
    }
}

extension SignInSheet {
    var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("How do you sign in to PlayStation?").font(.title3.weight(.semibold))
                Text("You sign in on Sony's own website. This app doesn't read or store your password; it keeps only what's needed to pair with your console.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { useSafari = true; chosen = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("With a passkey (Face ID or Touch ID)", systemImage: "person.badge.key.fill").font(.headline)
                        Text("Opens Safari, where your passkey works on this device.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("choosePasskey")
                Button { useSafari = false; chosen = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("With my email and password", systemImage: "envelope.fill").font(.headline)
                        Text("Shows Sony's sign-in page right here.").font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("choosePassword")
                Text("Not sure? Choose passkey if PlayStation normally signs you in with Face ID, Touch ID or your device passcode.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    /// Same sign-in, done in Safari where passkeys work. Sony's last page cannot send the result
    /// back to an app, so the person copies that page's address and pastes it here.
    @ViewBuilder func safariSteps(_ url: URL) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Card {
                    Text("STEP 1").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("Open Sony's sign-in page in Safari and sign in there. Your passkey works in Safari.").font(.subheadline)
                    Button { UIApplication.shared.open(url) } label: {
                        Label("Open sign-in in Safari", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("openSafariButton")
                }
                Card {
                    Text("STEP 2").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("When you've signed in, Safari shows a nearly empty page with the word “redirect”. Tap the address bar at the bottom or top of Safari, then tap Copy.")
                        .font(.subheadline)
                }
                Card {
                    Text("STEP 3").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("Come back to this app. It finishes by itself; if it doesn't, tap the button below.").font(.subheadline)
                    Button { pasteAddress() } label: {
                        Label("Paste the address I copied", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("pasteAddressButton")
                    if let pasteProblem {
                        Label(pasteProblem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Theme.bad)
                    }
                    Text("The address contains a one-time code that only works once and expires within minutes. iOS may ask you to allow the paste.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Sign in with email and password here instead") { useSafari = false }.font(.footnote)
            }
            .padding(16)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Safari with an address copied: finish without another tap.
            if phase == .active, !working, UIPasteboard.general.hasURLs { pasteAddress(quietIfWrong: true) }
        }
    }

    private func pasteAddress(quietIfWrong: Bool = false) {
        let text = (UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(signIn.redirectPrefix), let redirect = URL(string: text) else {
            if quietIfWrong { return }
            pasteProblem = "That isn't the address of the “redirect” page. Copy the address from Safari after signing in, then try again."
            return
        }
        pasteProblem = nil
        working = true
        Task {
            do {
                let stored = try await signIn.complete(redirect: redirect)
                onFinished(stored)
                dismiss()
            } catch let error as SessionFailure {
                failure = error
            } catch {
                failure = SessionFailure(code: .unknown, title: "Sign-in didn't finish",
                                         message: "The sign-in could not be completed. Check your internet connection.",
                                         recovery: ["Try again."])
            }
            working = false
        }
    }
}

private struct VendorWebView: UIViewRepresentable {
    let url: URL
    let redirectPrefix: String
    @Binding var host: String
    let onRedirect: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()   // nothing from the sign-in is kept on disk
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: VendorWebView
        private var finished = false
        init(_ parent: VendorWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let target = navigationAction.request.url, target.absoluteString.hasPrefix(parent.redirectPrefix) {
                decisionHandler(.cancel)
                if !finished { finished = true; parent.onRedirect(target) }
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.host = webView.url?.host ?? ""
        }
    }
}
