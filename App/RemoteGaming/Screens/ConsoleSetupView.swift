import SwiftUI
import RGPCore

struct ConsoleSetupView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var searching = false
    @State private var searchError: String?
    @State private var pin = ""
    /// Kept across app switches so going to the console and back does not restart setup.
    @AppStorage("setup.prepared") private var prepared = false
    @AppStorage("setup.address") private var manualAddress = ""
    @State private var showSignIn = false

    /// True when this source pairs with a vendor account and none is stored yet.
    private var needsSignIn: Bool {
        !model.demoMode && model.setupSource.accountSignIn != nil && !model.isSignedIn(model.setupKind)
    }
    @State private var pairing = false
    @State private var failure: SessionFailure?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 14) {
                if model.demoMode { DemoBanner() }
                if !model.demoMode, model.showExperimentalDevices {
                    Picker("Device type", selection: $model.setupKind) {
                        ForEach(ConsoleKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: model.setupKind) { _, _ in
                        model.setupFound = []; model.setupSelected = nil; model.setupSearched = false; failure = nil; pin = ""
                    }
                    .accessibilityIdentifier("kindPicker")
                }
                prepare
                if prepared || model.demoMode {
                    find.id("find")
                    if model.setupSelected != nil { pair.id("pair") }
                }
                if let failure { FailureCard(failure: failure).id("failure") }
                Text(model.showExperimentalDevices
                     ? "This app has no account of its own and never asks for your PlayStation or Microsoft password in its own screens."
                     : "This app has no account of its own. Your PlayStation password is only ever typed on Sony's own sign-in page, never into this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
        // Bring the step the person has just reached into view, so nothing waits off-screen.
        .onChange(of: prepared) { _, done in if done { scroll(proxy, "find") } }
        .onChange(of: model.setupSelected) { _, picked in if picked != nil { scroll(proxy, "pair") } }
        .onChange(of: failure) { _, f in if f != nil { scroll(proxy, "failure") } }
        }
        .background(Theme.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // The number pad has no Return key; give it a Done button so the Pair button can be reached.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
        .sheet(isPresented: $showSignIn) {
            if let signIn = model.setupSource.accountSignIn {
                SignInSheet(signIn: signIn) { model.storeAccount($0, for: model.setupKind) }
            }
        }
        .navigationTitle("Set up your console")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func scroll(_ proxy: ScrollViewProxy, _ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation { proxy.scrollTo(id, anchor: .top) }
        }
    }

    private var prepareTitle: String {
        switch model.setupKind {
        case .ps5: return model.demoMode ? "1 · ON THE CONSOLE" : "1 · ON YOUR PLAYSTATION 5"
        default: return "1 · PREPARE"
        }
    }

    private var prepare: some View {
        Card {
            Text(prepareTitle).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if prepared && !model.demoMode {
                // Finished: fold away so the next step is on screen, but keep a way back.
                HStack {
                    Label("Console settings done", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Theme.good)
                    Spacer()
                    Button("Show steps") { prepared = false }.font(.footnote)
                        .accessibilityIdentifier("showPrepareSteps")
                }
            } else {
                let steps = model.setupSource.setupSteps
                ForEach(Array(steps.enumerated()), id: \.offset) { index, text in step(index + 1, text) }
                if !model.demoMode {
                    Text("You do these on the PlayStation with its controller, looking at your TV. The app can't change them for you. They only need doing once.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { prepared = true } label: { Text("I've done this").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("preparedButton")
                }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").font(.footnote.weight(.bold)).frame(width: 22, height: 22)
                .background(Theme.accent.opacity(0.25), in: Circle())
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var find: some View {
        Card {
            Text("2 · FIND IT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Button { Task { await search() } } label: {
                HStack {
                    if searching { ProgressView().padding(.trailing, 4) }
                    Text(searching ? "Searching…" : (model.setupSearched ? "Search again" : "Search this network"))
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent).disabled(searching)
            .accessibilityIdentifier("searchButton")

            if !model.demoMode, model.setupSource.supportsPairing || model.setupKind == .ps5 {
                DisclosureGroup("Can't find it? Enter its address") {
                HStack {
                    TextField("IP address", text: $manualAddress)
                        .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                        .padding(8).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("ipField")
                    Button("Check") { Task { await search(address: manualAddress.trimmingCharacters(in: .whitespaces)) } }
                        .buttonStyle(.bordered).disabled(searching || manualAddress.isEmpty)
                }
                Text(model.setupKind == .computer ? "The address is shown in the CoastPlay Host window."
                     : "Find it on the console under Settings → Network → View Connection Status.").font(.caption).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }

            ForEach(model.setupFound) { console in
                Button { model.setupSelected = console; failure = nil } label: {
                    HStack {
                        Image(systemName: model.setupSelected == console ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading) {
                            Text(console.name)
                            Text(statusText(console)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("console-\(console.id)")
            }
            if model.setupSearched, model.setupFound.isEmpty, !searching {
                if model.setupSource.supportsPairing || model.setupKind == .ps5 {
                    Label(searchError ?? "Nothing answered.", systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(Theme.bad)
                    Text("Check it is on, on the same network, and that this app is allowed to use the local network (Settings → Privacy & Security → Local Network).")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Label(model.setupSource.unavailableNote, systemImage: "hammer.fill").font(.subheadline).foregroundStyle(Theme.demo)
                }
            }
        }
    }

    private func statusText(_ console: DiscoveredConsole) -> String {
        if model.demoMode { return "Simulated — not a real console" }
        if console.kind == .computer { return console.address.hasPrefix("bonjour:") ? "Found on this network" : console.address }
        switch console.status {
        case .ready: return "\(console.address) · On"
        case .standby: return "\(console.address) · Rest mode"
        case .unknown: return console.address
        }
    }

    private var pair: some View {
        Card {
            Text("3 · PAIR").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            if !model.setupSource.supportsPairing {
                Label("Found it, but pairing is not available in this build.", systemImage: "hammer.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.demo)
                Text(model.setupSource.unavailableNote).font(.footnote).foregroundStyle(.secondary)
            } else {
            if needsSignIn {
                // One thing at a time: sign in first; the number comes after.
                Text("First, sign in with your PlayStation account").font(.subheadline.weight(.semibold))
                Text("Use the same account that's signed in on the console. You sign in on Sony's own page; this app never sees your password. After that, one last step: a number from your TV.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { showSignIn = true } label: {
                    Label("Sign in with PlayStation", systemImage: "person.crop.circle.badge.checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("signInButton")
            } else {
            if model.setupSource.accountSignIn != nil, !model.demoMode {
                Label("Signed in with PlayStation", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(Theme.good)
            }
            Text(model.setupSource.pairingHint).font(.subheadline)
            if model.demoMode {
                Text("Demo: any 8 digits work, e.g. 1234 5678.").font(.footnote).foregroundStyle(Theme.demo)
            }
            TextField("8-digit number", text: $pin)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit())
                .padding(10).background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("pinField")
                // Keep it to the 8 digits the console shows, so extra or pasted characters can't
                // leave the Pair button greyed out with no explanation.
                .onChange(of: pin) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(8))
                    if digits != value { pin = digits }
                }
            Button { Task { await doPair() } } label: {
                HStack {
                    if pairing { ProgressView().padding(.trailing, 4) }
                    Text(pairing ? "Pairing…" : "Pair").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent).disabled(pairing || needsSignIn || pin.filter(\.isNumber).count != 8)
            .accessibilityIdentifier("pairButton")
            }
            }
        }
    }

    private func search(address: String? = nil) async {
        searching = true; searchError = nil; failure = nil; model.setupSelected = nil
        do { model.setupFound = try await model.setupSource.discover(address: address, timeout: 3) }
        catch { model.setupFound = []; searchError = address == nil ? "Search failed: the network request could not be sent." : "That address could not be checked. Make sure it looks like 192.168.1.50." }
        searching = false; model.setupSearched = true
        if model.setupFound.count == 1 { model.setupSelected = model.setupFound[0] }
    }

    private func doPair() async {
        guard let console = model.setupSelected else { return }
        pairing = true; failure = nil
        do {
            let (descriptor, secret) = try await model.setupSource.register(PairingRequest(console: console, pin: pin, accountIdentifier: model.accountIdentifier(for: model.setupKind)))
            try model.save(descriptor, secret: secret)
            pin = ""
            prepared = false
            dismiss()
        } catch let error as SessionFailure {
            failure = error
        } catch {
            failure = SessionFailure(code: .unknown, title: "Couldn't save the pairing",
                                     message: "The pairing could not be stored securely on this device.",
                                     recovery: ["Unlock the device and try again."])
        }
        pin = ""   // never keep the PIN around
        pairing = false
    }
}
