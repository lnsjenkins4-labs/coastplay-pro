import SwiftUI
import Combine
import RGPCore
import RGPMock
import RGPPS5
import RGPMirror
#if PROTOTYPE_CHIAKI
// Only the private prototype project (prototype-agpl/ios) sets this flag. The normal app never
// links the AGPL library.
import RGPChiaki
#endif

@main
struct RemoteGamingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.session)
                .environmentObject(model.controllers)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// App-level state: saved consoles (non-secret, UserDefaults), credential store (Keychain),
/// and the choice between the real PS5 source and the clearly-labelled demo source.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var consoles: [ConsoleDescriptor] = []
    @Published var demoMode: Bool { didSet { UserDefaults.standard.set(demoMode, forKey: "demoMode") } }
    @Published var scenario: MockScenario = .healthy { didSet { mockSource.scenario = scenario } }

    let credentials: CredentialStore = KeychainCredentialStore()
    let session: SessionController
    let controllers = GameControllerProvider()
    /// Physical controller + on-screen controls, merged, on the fast path to the console.
    private(set) var inputMixer: InputMixer?

    /// The person's button layout, saved on this device and applied whenever they play.
    @Published var buttonMapping = ButtonMapping.default {
        didSet {
            inputMixer?.setMapping(buttonMapping)
            if let data = try? JSONEncoder().encode(buttonMapping) { UserDefaults.standard.set(data, forKey: "buttonMapping.v1") }
        }
    }

    /// App Store plans. Enforcement stays OFF until the four plans exist in App Store Connect
    /// and have been tested in the sandbox, so a working phone is never locked out by accident.
    let store = StoreManager()
    @Published var showPlans = false
    /// Version 1.1 store build: purchases are on. Other builds keep the old test switch.
    var billingEnforced: Bool {
        #if STORE_BUILD
        return true
        #else
        return UserDefaults.standard.bool(forKey: "billingEnforced")
        #endif
    }

    /// On-screen controls changed. Sends at once; the first real press also counts as "input sent".
    func touchInput(_ state: ControllerState) {
        inputMixer?.setTouch(state)
        if state != .neutral, session.state == .playing, !session.isDemoSession {
            note { if $0.inputSentAt == nil { $0.inputSentAt = Date() } }
        }
    }
    private let mockSource = MockConsoleSource()
    private let ps5Source: ConsoleSource = {
        #if PROTOTYPE_CHIAKI
        return ChiakiConsoleSource()
        #else
        return PS5ConsoleSource()
        #endif
    }()
    private let computerSource = MirrorConsoleSource()
    private let xboxSource = XboxConsoleSource()
    /// Which kind of device Console Setup is adding. PlayStation 5 unless experimental types are shown.
    @Published var setupKind: ConsoleKind = .ps5
    /// Off by default: Xbox and Computer are not ready for customers and stay out of the normal path.
    @Published var showExperimentalDevices: Bool {
        didSet {
            UserDefaults.standard.set(showExperimentalDevices, forKey: "showExperimentalDevices")
            if !showExperimentalDevices { setupKind = .ps5 }
        }
    }
    /// Device types Console Setup offers. The store build offers PlayStation 5 and Computer
    /// (a Mac running CoastPlay Host); Xbox is a placeholder and stays hidden there.
    var setupKinds: [ConsoleKind] {
        #if STORE_BUILD
        return [.ps5, .computer]
        #else
        return showExperimentalDevices ? ConsoleKind.allCases : [.ps5]
        #endif
    }
    var showKindPicker: Bool {
        #if STORE_BUILD
        return true
        #else
        return showExperimentalDevices
        #endif
    }
    /// What has actually been observed per saved console (never recorded for demo sessions).
    @Published private(set) var readiness: [String: ReadinessRecord] = [:]
    /// Set when the app went to the background mid-session and the session was closed cleanly.
    @Published var pausedConsole: ConsoleDescriptor?
    /// Vendor accounts with a stored sign-in.
    @Published private(set) var signedInKinds: Set<ConsoleKind> = []
    /// Setup progress, kept here so it survives leaving the screen or switching apps.
    @Published var setupFound: [DiscoveredConsole] = []
    @Published var setupSelected: DiscoveredConsole?
    @Published var setupSearched = false
    private var observers: Set<AnyCancellable> = []
    private let readinessKey = "readiness.v1"
    /// The device's own screen and speakers. Used only for real (non-demo) sessions.
    let display = NativeDisplayDestination()
    /// Remote control for OBS on the creator's computer (Creator Mode).
    let obs = OBSRemote()
    static let isPrivatePrototype: Bool = {
        #if PROTOTYPE_CHIAKI && !STORE_BUILD
        return true
        #else
        return false
        #endif
    }()
    private let consolesKey = "savedConsoles.v1"

    init() {
        demoMode = UserDefaults.standard.bool(forKey: "demoMode")
        #if STORE_BUILD
        // The store build is PlayStation 5 only: the computer host has no public download yet
        // and Xbox is a placeholder.
        showExperimentalDevices = false
        #else
        showExperimentalDevices = UserDefaults.standard.bool(forKey: "showExperimentalDevices")
        #endif
        session = SessionController(credentials: credentials)
        if let data = UserDefaults.standard.data(forKey: readinessKey),
           let saved = try? JSONDecoder().decode([String: ReadinessRecord].self, from: data) {
            readiness = saved
        }
        if let data = UserDefaults.standard.data(forKey: consolesKey),
           let saved = try? JSONDecoder().decode([ConsoleDescriptor].self, from: data) {
            consoles = saved
        }
        // "Record play quality" is OFF for new users (owner's decision, 2026-11-16). A device that
        // already has a paired console when this version first runs was testing with it on, so
        // it keeps it on; either way the person can change it in Settings.
        if UserDefaults.standard.object(forKey: "recordPlayQuality") == nil {
            UserDefaults.standard.set(consoles.contains { !$0.isDemo }, forKey: "recordPlayQuality")
        }
        // One-time correction: an earlier build could take the internet route while on home
        // Wi-Fi and wrongly record "away from home tested". Clear those marks once.
        if !UserDefaults.standard.bool(forKey: "awayMarksReset.1") {
            for id in readiness.keys { readiness[id]?.awayTestedAt = nil }
            UserDefaults.standard.set(true, forKey: "awayMarksReset.1")
            if let data = try? JSONEncoder().encode(readiness) { UserDefaults.standard.set(data, forKey: readinessKey) }
        }
        CreatorHub.shared.attach(to: display)
        #if DEBUG
        CreatorSelfTest.runIfRequested(display: display)
        #endif
        for kind in ConsoleKind.allCases {
            let source = realSource(kind)
            if let stored = try? credentials.load(for: accountKey(kind)) {
                signedInKinds.insert(kind)
                source.account = stored.data
            }
            source.onConsoleMoved = { [weak self] id, address in
                Task { @MainActor in
                    guard let self, let index = self.consoles.firstIndex(where: { $0.id == id }) else { return }
                    self.consoles[index].lastKnownAddress = address
                    self.persist()
                }
            }
            // The source refreshes Sony's tokens when it needs to; keep the stored copy current.
            source.onAccountUpdated = { [weak self] data in
                Task { @MainActor in try? self?.credentials.save(PairingSecret(data: data), for: "account-\(kind.rawValue)") }
            }
        }
        // Consoles saved before readiness tracking existed are paired by definition (they have a
        // saved pairing); record that so the list does not wrongly show them as unpaired.
        for console in consoles where !console.isDemo && readiness[console.id]?.registeredAt == nil {
            var record = readiness[console.id] ?? ReadinessRecord()
            record.registeredAt = console.lastConnected ?? Date()
            readiness[console.id] = record
        }
        let liveSession = session
        let mixer = InputMixer { state in liveSession.sendImmediately(state) }   // fast path
        inputMixer = mixer
        if let data = UserDefaults.standard.data(forKey: "buttonMapping.v1"),
           let saved = try? JSONDecoder().decode(ButtonMapping.self, from: data) {
            buttonMapping = saved
        }
        mixer.setMapping(buttonMapping)
        controllers.onInputImmediate = { state in mixer.setPhysical(state) }
        controllers.onInput = { [weak self] state in
            guard let self else { return }
            if self.session.state == .playing, state != .neutral { self.note { if $0.inputSentAt == nil { $0.inputSentAt = Date() } } }
        }
        session.$state.removeDuplicates().sink { state in CreatorHub.shared.sessionActive = state.isActive }.store(in: &observers)
        session.$state.removeDuplicates().sink { [weak self] state in
            guard self?.session.isDemoSession == false else { return }
            switch state {
            case .playing:
                if CreatorHub.isEnabled || CreatorHub.shared.externalConnected {
                    let screens = UIApplication.shared.openSessions.map { $0.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: "") }
                    ConnectionLog.shared.add("Creator Mode \(CreatorHub.isEnabled ? "on" : "off"). Displays in use: \(screens.joined(separator: ", ")). External output: \(CreatorHub.shared.externalConnected ? "showing" : "not connected").")
                }
                ConnectionLog.shared.add("Playing (\(self?.session.isLocalRoute == true ? "home network route" : "away route")).")
            case .interrupted(let reason): ConnectionLog.shared.add("Interrupted: \(reason).")
            case .reconnecting(let attempt, let max): ConnectionLog.shared.add("Reconnecting, attempt \(attempt) of \(max).")
            case .failed(let failure): ConnectionLog.shared.add("Failed: \(failure.title). \(failure.message)")
            case .disconnected: ConnectionLog.shared.add("Disconnected.")
            default: break
            }
        }.store(in: &observers)
        session.$state.sink { [weak self] state in
            if state == .playing { self?.note { if $0.connectedAt == nil { $0.connectedAt = Date() } } }
        }.store(in: &observers)
        session.$stats.sink { [weak self] stats in
            // A picture counts only when frames from a real (not simulated) stream are arriving.
            guard let self, let stats, !stats.isSimulated, (stats.framesPerSecond ?? 0) > 1 else { return }
            let local = self.session.isLocalRoute   // how this session was actually opened
            // An engineering test can force the internet route while still at home; that must
            // never be recorded as an away-from-home success.
            if !local, UserDefaults.standard.bool(forKey: "forceRemote") { return }
            self.note {
                if $0.streamDisplayedAt == nil { $0.streamDisplayedAt = Date() }
                if local { if $0.homeTestedAt == nil { $0.homeTestedAt = Date() } }
                else if $0.awayTestedAt == nil { $0.awayTestedAt = Date() }
            }
        }.store(in: &observers)
        #if DEBUG
        prototypeTestHooks()
        #endif
    }

    #if DEBUG
    /// Set by `-autoPlay YES`: Home starts the first saved console as soon as it appears.
    @Published var autoPlayRequested = UserDefaults.standard.bool(forKey: "autoPlay")

    /// Engineering-only hooks (debug builds only), so a session can be driven without a
    /// person tapping: a one-shot pairing import file, and scripted D-pad taps.
    private func prototypeTestHooks() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let importURL = docs.appendingPathComponent("prototype-import.json")
        if let data = try? Data(contentsOf: importURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let id = obj["id"], let name = obj["name"], let address = obj["address"],
           let cred = obj["cred"].flatMap({ Data(base64Encoded: $0) }) {
            let kind = obj["kind"].flatMap(ConsoleKind.init(rawValue:)) ?? .ps5
            try? save(ConsoleDescriptor(id: id, name: name, kind: kind, lastKnownAddress: address, isDemo: false),
                      secret: PairingSecret(data: cred))
        }
        // Engineering shortcut: seed the home internet address for the direct away route when the
        // device cannot learn it itself (for example it is already away from home).
        if let data = try? Data(contentsOf: importURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let address = obj["homeInternetAddress"] {
            for console in consoles where console.kind == .ps5 && !console.isDemo {
                UserDefaults.standard.set(address, forKey: "homeInternetAddress.\(console.id)")
            }
            ConnectionLog.shared.add("Home internet address supplied for testing.")
        }
        try? FileManager.default.removeItem(at: importURL)   // never leave key material in a file

        if let taps = UserDefaults.standard.string(forKey: "autoTaps") {
            let names = taps.split(separator: ",").map(String.init)
            let buttons: [String: ControllerButtons] = ["up": .dpadUp, "down": .dpadDown, "left": .dpadLeft, "right": .dpadRight,
                                                        "cross": .cross, "circle": .circle, "ps": .ps]
            Task { @MainActor [weak self] in
                while self?.session.state != .playing { try? await Task.sleep(nanoseconds: 200_000_000) }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                for name in names {
                    guard let self, let button = buttons[name] else { continue }
                    var pressed = ControllerState(); pressed.buttons = button
                    self.session.send(pressed)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self.session.send(.neutral)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }
    #endif

    /// Consoles shown for the current mode. Demo consoles never appear outside demo mode.
    var visibleConsoles: [ConsoleDescriptor] {
        consoles.filter { $0.isDemo == demoMode }
            .sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }
    }

    /// Picture settings. Away from home defaults to a smaller picture for a quicker response.
    var streamConfig: StreamConfig {
        let d = UserDefaults.standard
        var config = StreamConfig()
        if d.integer(forKey: "homeHeight") == 1080 { config.width = 1920; config.height = 1080 }
        if d.integer(forKey: "frameRate") == 30 { config.fps = 30 }
        if d.string(forKey: "awayQuality") != "sharp" {
            config.awayWidth = 960; config.awayHeight = 540
        } else {
            config.awayWidth = 1280; config.awayHeight = 720
        }
        let home = d.integer(forKey: "bitrateKbps"), away = d.integer(forKey: "awayBitrateKbps")
        config.requestedBitrateKbps = home > 0 ? home : nil
        config.awayRequestedBitrateKbps = away > 0 ? away : nil
        return config
    }

    private func realSource(_ kind: ConsoleKind) -> ConsoleSource {
        switch kind {
        case .ps5: return ps5Source
        case .computer: return computerSource
        case .xbox: return xboxSource
        }
    }

    var setupSource: ConsoleSource { demoMode ? mockSource : realSource(setupKind) }

    func source(for console: ConsoleDescriptor) -> ConsoleSource { console.isDemo ? mockSource : realSource(console.kind) }

    func save(_ console: ConsoleDescriptor, secret: PairingSecret) throws {
        try credentials.save(secret, for: console.id)
        consoles.removeAll { $0.id == console.id }
        consoles.append(console)
        persist()
        if !console.isDemo {
            var record = readiness[console.id] ?? ReadinessRecord()
            if record.registeredAt == nil { record.registeredAt = Date() }
            readiness[console.id] = record
            persistReadiness()
        }
        setupFound = []; setupSelected = nil; setupSearched = false
    }

    // MARK: Vendor account (kept in the Keychain; never a password)

    private func accountKey(_ kind: ConsoleKind) -> String { "account-\(kind.rawValue)" }

    func isSignedIn(_ kind: ConsoleKind) -> Bool { signedInKinds.contains(kind) }

    func storeAccount(_ data: Data, for kind: ConsoleKind) {
        try? credentials.save(PairingSecret(data: data), for: accountKey(kind))
        signedInKinds.insert(kind)
        realSource(kind).account = data
    }

    func signOut(_ kind: ConsoleKind) {
        try? credentials.delete(for: accountKey(kind))
        signedInKinds.remove(kind)
        realSource(kind).account = nil
    }

    /// The identifier pairing needs, taken from the stored sign-in. nil if not signed in.
    func accountIdentifier(for kind: ConsoleKind) -> String? {
        guard let stored = try? credentials.load(for: accountKey(kind)) else { return nil }
        return realSource(kind).accountSignIn?.accountIdentifier(from: stored.data)
    }

    /// Updates the readiness record of the console in the current real session.
    private func note(_ change: (inout ReadinessRecord) -> Void) {
        guard !session.isDemoSession, let id = session.console?.id else { return }
        var record = readiness[id] ?? ReadinessRecord()
        let before = record
        change(&record)
        guard record != before else { return }
        readiness[id] = record
        persistReadiness()
    }

    /// The person's own answer to "did the console respond to your controller?".
    func confirmInput(_ worked: Bool, for console: ConsoleDescriptor) {
        guard !console.isDemo else { return }
        var record = readiness[console.id] ?? ReadinessRecord()
        record.inputConfirmedByUser = worked
        readiness[console.id] = record
        persistReadiness()
    }

    private func persistReadiness() {
        if let data = try? JSONEncoder().encode(readiness) { UserDefaults.standard.set(data, forKey: readinessKey) }
    }

    /// Removes every saved console, its pairing and its history from this device.
    func forgetEverything() {
        for console in consoles { try? credentials.delete(for: console.id) }
        for kind in ConsoleKind.allCases { signOut(kind) }
        consoles = []; readiness = [:]; pausedConsole = nil
        persist(); persistReadiness()
    }

    /// Called when the app opens or comes back: lets sources get ready for away-from-home play.
    func appDidBecomeActive() {
        let saved = consoles
        for kind in ConsoleKind.allCases {
            if let preparing = realSource(kind) as? AwayPreparing {
                Task { await preparing.prepareForAway(consoles: saved) }
            }
        }
    }

    /// Called when the app leaves the foreground: streaming cannot continue, so end it cleanly
    /// and remember what to offer when the person comes back.
    func appDidEnterBackground() {
        guard session.state.isActive, let console = session.console else { return }
        pausedConsole = console
        Task { await session.disconnect() }
    }

    /// Removes the console and deletes its pairing material from the Keychain.
    func forget(_ console: ConsoleDescriptor) {
        try? credentials.delete(for: console.id)
        consoles.removeAll { $0.id == console.id }
        readiness[console.id] = nil
        if pausedConsole?.id == console.id { pausedConsole = nil }
        persist(); persistReadiness()
    }

    /// False when a plan is needed first (only when plans are switched on). Shows the plan screen.
    func mayPlay(_ console: ConsoleDescriptor) -> Bool {
        guard billingEnforced, !console.isDemo else { return true }
        if store.access(to: console.kind) == .allowed { return true }
        showPlans = true
        return false
    }

    /// IDs of saved consoles that answered a search of this network just now (nil = not checked yet).
    @Published private(set) var answeringNow: Set<String>?

    /// Looks for consoles on this network so the Devices list can say which saved entries are
    /// really there. A PS5 reports a different ID on Wi-Fi and on a cable, so one console can
    /// end up saved twice; this is what tells the two entries apart.
    func refreshAnswering() async {
        guard !demoMode, consoles.contains(where: { !$0.isDemo && $0.kind == .ps5 }) else { answeringNow = nil; return }
        let found = (try? await realSource(.ps5).discover(address: nil, timeout: 2)) ?? []
        answeringNow = Set(found.map(\.id))
    }

    /// Other saved consoles with the same name and kind (likely the same console saved twice).
    func twins(of console: ConsoleDescriptor) -> [ConsoleDescriptor] {
        consoles.filter { $0.id != console.id && !$0.isDemo && $0.kind == console.kind
            && $0.name.caseInsensitiveCompare(console.name) == .orderedSame }
    }

    func rename(_ console: ConsoleDescriptor, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = consoles.firstIndex(where: { $0.id == console.id }) else { return }
        consoles[index].name = String(trimmed.prefix(40))
        persist()
    }

    func play(_ console: ConsoleDescriptor) {
        pausedConsole = nil
        if let index = consoles.firstIndex(where: { $0.id == console.id }) {
            consoles[index].lastConnected = Date()
            persist()
        }
        session.connect(to: console, using: source(for: console), config: streamConfig, destination: console.isDemo ? nil : display)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(consoles) { UserDefaults.standard.set(data, forKey: consolesKey) }
    }
}

enum Theme {
    static let accent = Color(red: 0.36, green: 0.55, blue: 1.0)
    static let background = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let card = Color(red: 0.10, green: 0.12, blue: 0.18)
    static let demo = Color(red: 1.0, green: 0.72, blue: 0.2)
    static let good = Color(red: 0.3, green: 0.85, blue: 0.55)
    static let bad = Color(red: 1.0, green: 0.42, blue: 0.42)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Shown on every screen while demo mode is on.
struct DemoBanner: View {
    var body: some View {
        Label("DEMO MODE — simulated console. No PS5 is connected.", systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Theme.demo, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("demoBanner")
    }
}

struct FailureCard: View {
    let failure: SessionFailure
    var body: some View {
        Card {
            Label(failure.title, systemImage: "xmark.octagon.fill").font(.headline).foregroundStyle(Theme.bad)
            Text(failure.message).font(.subheadline)
            ForEach(failure.recovery, id: \.self) { step in
                Label(step, systemImage: "arrow.right.circle").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
