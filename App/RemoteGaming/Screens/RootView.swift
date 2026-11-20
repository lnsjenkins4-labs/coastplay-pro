import SwiftUI
import RGPCore
import RGPMock

/// Root of the app: Play, Devices, Help, Settings.
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var controllers: GameControllerProvider
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPlayer = false

    var body: some View {
        TabView {
            NavigationStack { PlayTab(start: start) }
                .tabItem { Label("Play", systemImage: "play.fill") }
            NavigationStack { DevicesTab(start: start) }
                .tabItem { Label("Devices", systemImage: "tv.and.mediabox") }
            NavigationStack { HelpTab() }
                .tabItem { Label("Help", systemImage: "questionmark.circle") }
            NavigationStack { SettingsTab() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .sheet(isPresented: $model.showPlans) {
            NavigationStack {
                PlansView(store: model.store).environmentObject(model)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.showPlans = false } } }
            }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            PlayerView().environmentObject(model).environmentObject(session).environmentObject(controllers)
        }
        .onChange(of: scenePhase) { _, phase in
            // Streaming cannot continue in the background; end it cleanly and offer to resume.
            if phase == .background {
                model.appDidEnterBackground()
                showPlayer = false
            } else if phase == .active {
                model.appDidBecomeActive()
            }
        }
        .task { model.appDidBecomeActive() }     // first launch: the phase may already be active
        #if DEBUG
        .onAppear {
            if model.autoPlayRequested, let first = model.visibleConsoles.first {
                model.autoPlayRequested = false
                start(first)
            }
        }
        #endif
    }

    private func start(_ console: ConsoleDescriptor) {
        guard model.mayPlay(console) else { return }
        model.play(console)
        showPlayer = true
    }
}

// MARK: - Play

struct PlayTab: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var controllers: GameControllerProvider
    let start: (ConsoleDescriptor) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                BrandHeader()
                if model.demoMode { DemoBanner() }
                if let paused = model.pausedConsole, model.visibleConsoles.contains(paused) {
                    Card {
                        Label("Your session was closed when you left the app", systemImage: "pause.circle.fill").font(.headline)
                        Text("Streaming can't continue in the background. The game is still running on the console.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { start(paused) } label: {
                            Label("Resume on \(paused.name)", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("resumeButton")
                    }
                }
                if let recent = model.visibleConsoles.first, !recent.isDemo {
                    GettingStartedCard(console: recent, record: model.readiness[recent.id] ?? ReadinessRecord())
                }
                if let recent = model.visibleConsoles.first {
                    Card {
                        Text(recent.lastConnected == nil ? "READY" : "LAST PLAYED").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        HStack {
                            Image(systemName: "gamecontroller.fill").font(.title).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading) {
                                Text(recent.name).font(.title3.weight(.semibold))
                                if !recent.isDemo, recent.kind == .ps5, let answering = model.answeringNow {
                                    if answering.contains(recent.id) {
                                        Label("On this network and ready", systemImage: "dot.radiowaves.left.and.right")
                                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.good)
                                    } else {
                                        Label("Not on this network. Play will try the away-from-home route.", systemImage: "globe")
                                            .font(.footnote).foregroundStyle(Theme.demo)
                                    }
                                }
                                if let date = recent.lastConnected {
                                    Text(date.formatted(.relative(presentation: .named))).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button { start(recent) } label: {
                            Label(recent.isDemo ? "Play (demo)" : "Play", systemImage: "play.fill")
                                .font(.title3.weight(.bold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("playButton")
                        controllerLine
                    }
                    if model.visibleConsoles.count > 1 {
                        Card {
                            Text("YOUR OTHER CONSOLES").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            ForEach(model.visibleConsoles.dropFirst()) { console in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(console.name).font(.subheadline.weight(.semibold))
                                        Text((console.lastConnected.map { "Last played \($0.formatted(.relative(presentation: .named)))" } ?? "Not played yet")
                                             + (model.twins(of: console).isEmpty ? "" : " · same name as another saved console, see Devices"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Play") { start(console) }.buttonStyle(.bordered)
                                        .accessibilityIdentifier("play-\(console.id)")
                                }
                            }
                        }
                    }
                } else {
                    firstRun
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Play")
        .task { await model.refreshAnswering() }
        .refreshable { await model.refreshAnswering() }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var controllerLine: some View {
        NavigationLink { ControllerSetupView() } label: {
            Label(controllers.active.map { "Controller: \($0.name)" } ?? "No controller connected — tap to set one up",
                  systemImage: "gamecontroller")
                .font(.footnote).foregroundStyle(controllers.active != nil ? Theme.good : Theme.demo)
        }
    }

    private var firstRun: some View {
        Group {
            Card {
                Text("Play games from your own console on this device").font(.title3.weight(.semibold))
                Text("The game runs on your console. This app shows its picture and sound here and sends your controller back to it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            NavigationLink { ConsoleSetupView() } label: {
                Label(model.demoMode ? "Set up the demo console" : "Set up my PlayStation 5", systemImage: "plus.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("setupButton")
            Text("Takes about five minutes. Be at home, near your PlayStation and TV.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            RequirementsCard()
        }
    }
}

/// The few steps between pairing and a confirmed first session, ticked off as they really
/// happen. Disappears once home play is confirmed and the away test has been run.
struct GettingStartedCard: View {
    @EnvironmentObject var controllers: GameControllerProvider
    let console: ConsoleDescriptor
    let record: ReadinessRecord

    private var controllerDone: Bool { controllers.active != nil || record.inputConfirmedByUser == true }
    private var homeDone: Bool { record.homeTestedAt != nil }
    private var awayDone: Bool { record.awayTestedAt != nil }

    var body: some View {
        if !(homeDone && controllerDone && awayDone) {
            Card {
                Text(homeDone && controllerDone ? "ONE OPTIONAL STEP LEFT" : "GETTING STARTED").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                row(true, "Pair your PlayStation", nil)
                NavigationLink { ControllerSetupView() } label: {
                    row(controllerDone, "Connect a controller to this device", controllerDone ? nil : "Tap for Bluetooth or cable steps")
                }
                row(homeDone, "Play once on your home Wi-Fi", homeDone ? nil : "Press Play below while at home")
                NavigationLink { AwayTestView(console: console) } label: {
                    row(awayDone, "Optional: test playing away from home", awayDone ? nil : "Tap to test from mobile data or other Wi-Fi")
                }
            }
            .accessibilityIdentifier("gettingStartedCard")
        }
    }

    private func row(_ done: Bool, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.good : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).foregroundStyle(.white)
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.accent) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Plain-text report a person can choose to send to support. Built only from things that are
/// safe to share: device model, system and app version, and the connection log.
enum SupportReport {
    static func text() -> String {
        var system = utsname(); uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return """
        CoastPlay PRO support report
        App version: \(version)
        Device: \(model), iOS \(UIDevice.current.systemVersion)

        What happened (please describe):


        Connection log (no passwords, keys, picture or sound):
        \(ConnectionLog.shared.text)
        """
    }
}

/// The owner's logo, shown as supplied (not redrawn or recoloured).
struct BrandHeader: View {
    var body: some View {
        if let logo = UIImage(named: "BrandLogo") {
            Image(uiImage: logo).resizable().scaledToFit()
                .padding(.horizontal, 8)
                .accessibilityLabel("CoastPlay PRO")
        }
    }
}

/// What a person needs before they start. Shown before setup and in Help.
struct RequirementsCard: View {
    var body: some View {
        Card {
            Text("WHAT YOU NEED").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            need("tv.and.mediabox", "Your own PlayStation 5", "Switched on or in rest mode. We don't provide a console or games.")
            need("person.crop.circle", "Your PlayStation account", "The one signed in on that console. You sign in on Sony's own page; there's no separate account with us.")
            need("iphone", "This iPhone or iPad", "The app is still in testing; other devices are planned.")
            need("wifi", "A good connection", "Start on the same Wi-Fi as the console. Away from home is new and does not work on every network. Sony suggests at least 5 Mbps, and 15 Mbps for best results.")
            need("gamecontroller", "A controller, or your thumbs", "A controller connected to this device by Bluetooth or cable plays best. On-screen controls are built in if you don't have one with you.")
        }
    }

    private func need(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 26).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Devices

struct DevicesTab: View {
    @EnvironmentObject var model: AppModel
    let start: (ConsoleDescriptor) -> Void
    @State private var forgetTarget: ConsoleDescriptor?
    @State private var renameTarget: ConsoleDescriptor?
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.demoMode { DemoBanner() }
                ForEach(model.visibleConsoles) { console in deviceCard(console) }
                if model.visibleConsoles.isEmpty {
                    Card { Text("No saved consoles yet.").foregroundStyle(.secondary) }
                }
                NavigationLink { ConsoleSetupView() } label: {
                    Label("Add a console", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                #if DEBUG
                // Test builds only: a direct way to add this Mac, without hunting for the
                // experimental switch. Not shown to customers until computer play is verified.
                if !model.demoMode {
                    NavigationLink {
                        ConsoleSetupView().onAppear { model.showExperimentalDevices = true; model.setupKind = .computer }
                    } label: {
                        Label("Add a computer (test)", systemImage: "desktopcomputer").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered).tint(Theme.demo)
                    .accessibilityIdentifier("addComputerTest")
                }
                #endif
                NavigationLink { CompatibilityView() } label: {
                    Label("Which devices are supported?", systemImage: "checklist").font(.subheadline)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Devices")
        .task { await model.refreshAnswering() }
        .refreshable { await model.refreshAnswering() }
        .confirmationDialog("Forget this console?", isPresented: Binding(get: { forgetTarget != nil }, set: { if !$0 { forgetTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Forget and delete pairing", role: .destructive) {
                if let target = forgetTarget { model.forget(target) }
                forgetTarget = nil
            }
        } message: {
            Text("This removes the console and deletes its saved pairing from this device. You will need to pair again to play.")
        }
        .alert("Name this console", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { if let target = renameTarget { model.rename(target, to: newName) }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        } message: {
            Text("Only changes the name shown in this app, to help tell your consoles apart.")
        }
    }

    /// Tells saved entries apart: is it answering on this network right now, when it was paired,
    /// and plain advice when two entries look like the same console.
    @ViewBuilder private func whichOne(_ console: ConsoleDescriptor) -> some View {
        let twins = model.twins(of: console)
        let paired = model.readiness[console.id]?.registeredAt
        if let answering = model.answeringNow {
            if answering.contains(console.id) {
                Label("Answering on this network now", systemImage: "dot.radiowaves.left.and.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.good)
            } else {
                Label("Not answering on this network right now", systemImage: "wifi.slash").font(.footnote).foregroundStyle(.secondary)
            }
        }
        if let paired {
            Text("Paired \(paired.formatted(date: .abbreviated, time: .shortened))" + (console.lastConnected.map { " · last played \($0.formatted(.relative(presentation: .named)))" } ?? " · never played"))
                .font(.caption).foregroundStyle(.secondary)
        }
        if !twins.isEmpty {
            let thisAnswers = model.answeringNow?.contains(console.id) == true
            let twinAnswers = twins.contains { model.answeringNow?.contains($0.id) == true }
            VStack(alignment: .leading, spacing: 4) {
                Label("Saved twice?", systemImage: "square.on.square").font(.footnote.weight(.semibold)).foregroundStyle(Theme.demo)
                Text("You have another saved console with this name. A PlayStation looks like a different device on Wi-Fi and on a network cable, so the same console can be saved once for each.")
                    .font(.caption).foregroundStyle(.secondary)
                if thisAnswers && !twinAnswers {
                    Text("This is the one in use now. Keep this one.").font(.caption.weight(.semibold)).foregroundStyle(Theme.good)
                } else if !thisAnswers && twinAnswers {
                    Text("This looks like the console's old connection. It is safe to remove with the bin button; the other entry keeps working. If you switch the console back to its old connection, this entry would be the one that works.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Be at home on the same network as the console and reopen this screen to see which one is in use.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("twinNote-\(console.id)")
        }
    }

    private func deviceCard(_ console: ConsoleDescriptor) -> some View {
        Card {
            HStack {
                VStack(alignment: .leading) {
                    Text(console.name).font(.headline)
                    Text(console.isDemo ? "Simulated" : [console.kind.displayName, console.lastKnownAddress.flatMap { NetworkAddress.isLocal($0) ? $0 : nil }].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                        .foregroundStyle(console.isDemo ? Theme.demo : .secondary)
                }
                Spacer()
                Button("Play") { start(console) }.buttonStyle(.borderedProminent)
                Button { newName = console.name; renameTarget = console } label: { Image(systemName: "pencil") }
                    .buttonStyle(.bordered).accessibilityLabel("Rename \(console.name)")
                Button(role: .destructive) { forgetTarget = console } label: { Image(systemName: "trash") }
                    .buttonStyle(.bordered).accessibilityLabel("Forget \(console.name)")
            }
            if !console.isDemo { whichOne(console) }
            if !console.isDemo {
                ReadinessList(record: model.readiness[console.id] ?? ReadinessRecord())
                if console.kind == .ps5 {
                    NavigationLink { AwayTestView(console: console) } label: {
                        Label("Test away from home", systemImage: "antenna.radiowaves.left.and.right").font(.subheadline)
                    }
                    .accessibilityIdentifier("awayTestLink")
                }
            }
        }
    }
}

/// A guided check of whether this device can reach the console from a different network.
/// It makes a real connection, waits for picture, then disconnects. A pass shows that this
/// network worked just now; it is not a promise about other networks.
struct AwayTestView: View {
    let console: ConsoleDescriptor
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: SessionController

    private enum Phase: Equatable {
        case intro, running
        case passed(seconds: Int)
        case stillAtHome
        case failed(SessionFailure)
    }
    @State private var phase: Phase = .intro
    @State private var measuredRoundTrip: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card {
                    Text("BEFORE YOU START").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Label("Leave the console switched on, or in rest mode with “Stay Connected to the Internet” turned on.", systemImage: "1.circle").font(.subheadline)
                    Label("Make sure you're signed in with PlayStation (Settings).", systemImage: "2.circle").font(.subheadline)
                    Label("Put this device on a different network: turn Wi-Fi off to use mobile data, or join another Wi-Fi.", systemImage: "3.circle").font(.subheadline)
                    Text("The test connects to your console for a few seconds and then disconnects. It can take up to two minutes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                switch phase {
                case .intro:
                    startButton("Start test")
                case .running:
                    Card {
                        HStack { ProgressView(); Text(session.progressText ?? "Connecting…").font(.subheadline) }
                        Text("Keep this screen open.").font(.footnote).foregroundStyle(.secondary)
                    }
                case .passed(let seconds):
                    Card {
                        Label("It worked from this network", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Theme.good)
                        Text("The console's picture arrived after \(seconds) seconds.").font(.subheadline)
                        if let rtt = measuredRoundTrip {
                            Text("Network round-trip: \(rtt) ms. \(rtt < 60 ? "That's good for most games." : rtt < 110 ? "Fine for most games; fast timing games may feel slightly behind." : "High. Fast timing games will feel behind on this network.")")
                                .font(.subheadline)
                        }
                        Text("This shows this network worked just now. Other networks, especially mobile data and hotel or office Wi-Fi, can behave differently.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    startButton("Test again")
                case .stillAtHome:
                    Card {
                        Label("You're still on the console's network", systemImage: "house.fill").font(.headline).foregroundStyle(Theme.demo)
                        Text("The console answered on your home network, so this would not be an away-from-home test. Turn Wi-Fi off, or join a different network, and try again.")
                            .font(.subheadline)
                    }
                    startButton("Try again")
                case .failed(let failure):
                    FailureCard(failure: failure)
                    Card {
                        Text("WHAT THIS MEANS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        Text("Playing at home is not affected. Away from home depends on the network this device is using and on your home router; some combinations cannot connect directly.")
                            .font(.footnote)
                        NavigationLink { RouterGuideView() } label: { Label("Step-by-step fix for mobile data", systemImage: "list.number") }.font(.subheadline)
                    }
                    startButton("Test again")
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Away-from-home test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { if phase == .running { Task { await session.disconnect() } } }
    }

    private func startButton(_ title: String) -> some View {
        Button { Task { await run() } } label: { Text(title).frame(maxWidth: .infinity).padding(.vertical, 4) }
            .buttonStyle(.borderedProminent)
            .disabled(session.state.isActive)
            .accessibilityIdentifier("awayTestStart")
    }

    private func run() async {
        phase = .running
        let source = model.source(for: console)
        // If the console answers on its home address, this is not an away test.
        if let host = console.lastKnownAddress, NetworkAddress.isLocal(host),
           let found = try? await source.discover(address: host, timeout: 1.5), !found.isEmpty {
            ConnectionLog.shared.add("Away test: not run, the console answered on the home network.")
            phase = .stillAtHome
            return
        }
        ConnectionLog.shared.add("Away test started.")
        let started = Date()
        session.connect(to: console, using: source, config: model.streamConfig, destination: nil)   // no picture or sound shown
        let deadline = Date().addingTimeInterval(170)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if case .failed(let failure) = session.state {
                ConnectionLog.shared.add("Away test: failed.")
                phase = .failed(failure)
                return
            }
            if session.state == .playing, (session.stats?.framesPerSecond ?? 0) > 1 {
                let seconds = Int(Date().timeIntervalSince(started))
                try? await Task.sleep(nanoseconds: 5_000_000_000)      // long enough for a round-trip reading
                measuredRoundTrip = session.stats?.roundTripMs.map { Int($0) }
                await session.disconnect()
                ConnectionLog.shared.add("Away test: passed in \(seconds) seconds.")
                phase = .passed(seconds: seconds)
                return
            }
        }
        await session.disconnect()
        ConnectionLog.shared.add("Away test: no picture within the time limit.")
        phase = .failed(.timedOut)
    }
}

/// Shows each thing that has actually been observed, separately.
struct ReadinessList: View {
    let record: ReadinessRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(ReadinessRecord.Step.allCases, id: \.self) { step in
                line(record.isDone(step), step.rawValue,
                     step == .inputConfirmed && record.inputConfirmedByUser == false ? "You reported it did not respond" : nil)
            }
            Divider().padding(.vertical, 2)
            line(record.homeTestedAt != nil, "Home network", record.homeTestedAt.map { "Tested \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Not tested yet")
            switch record.awayStatus {
            case .tested(let date): line(true, "Away from home", "Tested \(date.formatted(date: .abbreviated, time: .omitted)) — that network worked that day")
            case .notTested: line(false, "Away from home", "Not tested yet")
            }
        }
        .font(.footnote)
    }

    private func line(_ done: Bool, _ title: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Theme.good : .secondary)
            Text(title)
            if let detail { Text(detail).foregroundStyle(.secondary) }
        }
    }
}

struct CompatibilityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if model.demoMode { DemoBanner() }
                Text("A device is marked Hardware-verified only after a real console session — picture, sound and controller — has been played on that device with a build we can release. None have been yet.")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(CompatibilityEntry.matrix) { entry in
                    Card {
                        HStack {
                            Text(entry.device).font(.headline)
                            Spacer()
                            Text(entry.status.rawValue).font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(color(entry.status).opacity(0.2), in: Capsule())
                                .foregroundStyle(color(entry.status))
                        }
                        Text(entry.method).font(.subheadline)
                        Text(entry.note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Supported devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(_ status: CompatibilityEntry.Status) -> Color {
        switch status {
        case .planned: return .gray
        case .experimental: return Theme.demo
        case .hardwareVerified: return Theme.good
        }
    }
}

// MARK: - Help

struct HelpTab: View {
    @EnvironmentObject var model: AppModel

    private let problems: [(String, SessionFailure)] = [
        ("The app can't find or reach my console", .consoleUnreachable),
        ("The console refuses the connection", .remotePlayDisabled),
        ("The console won't wake from rest mode", .consoleAsleep),
        ("Someone else is using the console", .consoleBusy),
        ("The picture stopped during play", .connectionLost),
        ("Pairing was rejected", .pairingRejected),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.demoMode { DemoBanner() }
                RequirementsCard()
                WhatMustBeOnCard()
                Card {
                    Text("CONTROLLER").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    tip("Connect it to this device, not the console", "Bluetooth: hold Create + PS until the light flashes, then choose it in Settings → Bluetooth. Or plug it into this device with a cable.")
                    tip("The PS button", "iOS keeps the PS/Home button for its own use, so pressing it on the controller may not reach the console. Use the PS button on screen in the player instead.")
                    tip("The Create button", "iOS uses a double press for a screenshot and a long press for a recording. A single press still reaches the console.")
                    tip("On-screen controls", "No controller with you? In the player, tap the hand button at the top to show sticks and buttons over the game. They appear by themselves when no controller is connected. A real controller is still better for fast games.")
                    tip("Leaving a game", "Tap Disconnect at the top right of the player. The game keeps running on the console.")
                    NavigationLink { ControllerSetupView() } label: { Label("Check my controller", systemImage: "gamecontroller") }.font(.subheadline)
                    NavigationLink { RemapView() } label: { Label("Change the button layout", systemImage: "arrow.left.arrow.right") }.font(.subheadline)
                }
                Card {
                    Text("IF SOMETHING GOES WRONG").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(problems, id: \.0) { title, failure in
                        DisclosureGroup(title) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(failure.message).font(.footnote)
                                ForEach(failure.recovery, id: \.self) { Label($0, systemImage: "arrow.right.circle").font(.footnote).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                        }
                        .font(.subheadline)
                    }
                }
                Card {
                    Text("PLAYING AWAY FROM HOME").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    tip("Sign in first", "Away play needs your PlayStation sign-in (Settings). At home it isn't needed.")
                    tip("Test before you leave", "Devices → Test away from home makes a real connection from the network you're on and tells you plainly whether it worked.")
                    tip("It depends on the network", "Most home and public Wi-Fi works. Mobile data and some hotel or office networks often block direct connections; Sony's own Remote Play has the same limit.")
                    NavigationLink { RouterGuideView() } label: {
                        Label("Step-by-step: make it work on mobile data", systemImage: "list.number").font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier("routerGuideLink")
                }
                Card {
                    Text("STILL STUCK?").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    tip("Before you send one", "If play was choppy, turn on Settings → Record play quality and play for a minute first, so the report shows what the network was doing.")
                    tip("Send a report", "Creates a short report with this device's model, the app version and the connection log, and opens the share sheet so you can send it by email or message. It contains no passwords, keys, picture or sound. Nothing is sent unless you send it.")
                    ShareLink(item: SupportReport.text(), subject: Text("CoastPlay PRO support report")) {
                        Label("Create a support report", systemImage: "envelope").font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier("supportReportButton")
                }
                Card {
                    Text("GOOD TO KNOW").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    tip("Where the picture travels", "Straight from your console to this device over your own network. It does not pass through our servers; we don't run any.")
                    tip("Best connection", "Console on a network cable, this device on 5 GHz Wi-Fi near the router.")
                    tip("Not affiliated", "This app is not made or endorsed by Sony or Microsoft.")
                    NavigationLink { PolicyView() } label: {
                        Label("Our promise & refund policy", systemImage: "hand.raised").font(.subheadline.weight(.semibold))
                    }
                    .accessibilityIdentifier("policyLink")
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Help")
    }

    private func tip(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Recent connection attempts in plain language, for the person or for support.
struct ConnectionLogView: View {
    @State private var text = ConnectionLog.shared.text

    var body: some View {
        ScrollView {
            Text(text).font(.footnote.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Connection log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
                Button("Clear") { ConnectionLog.shared.clear(); text = ConnectionLog.shared.text }
            }
        }
        .onAppear { text = ConnectionLog.shared.text }
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @EnvironmentObject var model: AppModel

    /// The store build shows plans and the refund policy only once purchases are switched on
    /// (they are not in version 1.0); other builds always show them.
    private var showPlansEntry: Bool {
        #if STORE_BUILD
        return model.billingEnforced
        #else
        return true
        #endif
    }
    @State private var confirmRemoveAll = false
    @AppStorage("showDiagnostics") private var showDiagnostics = false
    @AppStorage("awayQuality") private var awayQuality = "fast"
    @AppStorage("recordPlayQuality") private var recordPlayQuality = false
    @AppStorage("touchControls") private var touchControls = false
    @AppStorage("homeHeight") private var homeHeight = 0
    @AppStorage("frameRate") private var frameRate = 0
    @AppStorage("bitrateKbps") private var bitrateKbps = 0
    @AppStorage("awayBitrateKbps") private var awayBitrateKbps = 0

    @ViewBuilder private var rateOptions: some View {
        Text("Automatic").tag(0)
        ForEach([2000, 4000, 6000, 8000, 10000, 15000, 20000], id: \.self) { Text("\($0 / 1000) Mbps").tag($0) }
    }
    @State private var showSignIn = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if model.demoMode { DemoBanner() }
                if let signIn = model.setupSource.accountSignIn, !model.demoMode {
                    Card {
                        Text("\(signIn.providerName.uppercased()) ACCOUNT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        if model.isSignedIn(model.setupKind) {
                            Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                            Text("Used only to pair with your console. Signing out keeps consoles you've already paired.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Sign out", role: .destructive) { model.signOut(model.setupKind) }
                                .accessibilityIdentifier("signOutButton")
                        } else {
                            Text("Not signed in. You'll be asked when you pair a console.").font(.footnote).foregroundStyle(.secondary)
                            Button("Sign in with \(signIn.providerName)") { showSignIn = true }
                        }
                    }
                }
                if showPlansEntry {
                Card {
                    Text("PLAN").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    NavigationLink { PlansView(store: model.store) } label: {
                        VStack(alignment: .leading) {
                            Text("Plans and subscription")
                            Text(model.store.entitlement.flatMap { $0.isCurrent() ? $0.product?.tier.displayName : nil } ?? (model.billingEnforced ? "No active plan" : "Not switched on in this test build"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("plansLink")
                }
                }
                Card {
                    Text("CREATOR").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    NavigationLink { CreatorPanel(obs: model.obs).navigationBarBackButtonHidden() } label: {
                        VStack(alignment: .leading) {
                            Text("Creator Mode")
                            Text("Send clean gameplay to OBS, record, save replays. Early version.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                        }
                    }
                    .accessibilityIdentifier("creatorLink")
                }
                Card {
                    Text("CONTROLLER").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    NavigationLink { RemapView() } label: {
                        VStack(alignment: .leading) {
                            Text("Button layout")
                            Text(model.buttonMapping.isDefault ? "Default. Change which button sends what." : "You're using your own layout.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("settingsRemapLink")
                    NavigationLink { ControllerSetupView() } label: { Text("Check my controller") }
                }
                Card {
                    Text("PICTURE").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    HStack { Text("At home").font(.subheadline); Spacer(); Picker("At home", selection: $homeHeight) {
                        Text("720p").tag(0)
                        Text("1080p").tag(1080)
                    }.labelsHidden() }
                    HStack { Text("Away from home").font(.subheadline); Spacer(); Picker("Away from home", selection: $awayQuality) {
                        Text("540p, faster").tag("fast")
                        Text("720p, sharper").tag("sharp")
                    }.labelsHidden() }
                    HStack { Text("Frame rate").font(.subheadline); Spacer(); Picker("Frame rate", selection: $frameRate) {
                        Text("60 a second").tag(0)
                        Text("30 a second").tag(30)
                    }.labelsHidden() }
                    HStack { Text("Data rate at home").font(.subheadline); Spacer(); Picker("Data rate at home", selection: $bitrateKbps) { rateOptions }.labelsHidden() }
                    HStack { Text("Data rate away").font(.subheadline); Spacer(); Picker("Data rate away", selection: $awayBitrateKbps) { rateOptions }.labelsHidden() }
                    Text("The first choice in each list is the default. These are what the app asks the console for; the console may send less on a weak connection. A smaller picture, a lower frame rate or a lower data rate can make play steadier on a slow network, at the cost of sharpness or smoothness. They cannot remove the delay of the network itself. Changes apply the next time you press Play. 1080p and custom data rates have not been confirmed on a real console yet.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset picture settings") { homeHeight = 0; awayQuality = "fast"; frameRate = 0; bitrateKbps = 0; awayBitrateKbps = 0 }
                        .font(.subheadline)
                        .disabled(homeHeight == 0 && awayQuality == "fast" && frameRate == 0 && bitrateKbps == 0 && awayBitrateKbps == 0)
                        .accessibilityIdentifier("resetPicture")
                }
                Card {
                    Text("SAVED DATA").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Text("Pairings are kept in this device's Keychain. This app has no account of its own and stores no PlayStation password.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Remove all consoles and pairings", role: .destructive) { confirmRemoveAll = true }
                        .disabled(model.consoles.isEmpty)
                }
                Card {
                    Text("ADVANCED").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    Toggle(isOn: $model.demoMode) {
                        VStack(alignment: .leading) {
                            Text("Demo mode")
                            Text("A simulated console for trying the app. Not a real stream.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(Theme.demo)
                    .accessibilityIdentifier("demoToggle")
                    if model.demoMode {
                        Picker("Scenario", selection: $model.scenario) {
                            ForEach(MockScenario.allCases) { Text($0.title).tag($0) }
                        }
                        Text(model.scenario.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink { ConnectionLogView() } label: {
                        VStack(alignment: .leading) {
                            Text("Connection log")
                            Text("The steps of recent connection attempts. No passwords, keys, picture or sound.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("connectionLogLink")
                    Toggle(isOn: $touchControls) {
                        VStack(alignment: .leading) {
                            Text("On-screen controls")
                            Text("Shows sticks and buttons over the game. They also appear by themselves when no controller is connected. You can switch them in the player with the hand button.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("touchControlsToggle")
                    Toggle(isOn: $recordPlayQuality) {
                        VStack(alignment: .leading) {
                            Text("Record play quality")
                            Text("Adds one line to the connection log every 10 seconds while you play: picture rate, freezes and network delay. Off unless you turn it on. Stays on this device, uses almost no space, and does not slow the game. Turn it on before play if you want support to see what happened.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("recordQualityToggle")
                    Toggle(isOn: $showDiagnostics) {
                        VStack(alignment: .leading) {
                            Text("Show connection details while playing")
                            Text("A small box with resolution, frame rate and bitrate. Off by default.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("diagnosticsToggle")
                    #if !STORE_BUILD
                    Toggle(isOn: $model.showExperimentalDevices) {
                        VStack(alignment: .leading) {
                            Text("Show experimental device types")
                            Text("Adds Computer and Xbox to setup. Computer mirroring is an untested experiment; Xbox is a placeholder that cannot connect.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("experimentalToggle")
                    #endif
                }
                Card {
                    Text("ABOUT").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    if showPlansEntry {
                        NavigationLink { PolicyView() } label: { Label("Our promise & refund policy", systemImage: "hand.raised") }
                            .font(.subheadline)
                    }
                    NavigationLink { LicencesView() } label: { Label("Licences and source code", systemImage: "doc.text") }
                        .font(.subheadline)
                        .accessibilityIdentifier("licencesLink")
                    if AppModel.isPrivatePrototype {
                        Text("Private test build. PlayStation 5 streaming uses an open-source library under the AGPL licence and this build must not be distributed.")
                            .font(.footnote).foregroundStyle(Theme.demo)
                    }
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showSignIn) {
            if let signIn = model.setupSource.accountSignIn {
                SignInSheet(signIn: signIn) { model.storeAccount($0, for: model.setupKind) }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Remove everything?", isPresented: $confirmRemoveAll, titleVisibility: .visible) {
            Button("Remove all consoles and pairings", role: .destructive) { model.forgetEverything() }
        } message: {
            Text("This deletes every saved console and its pairing from this device. It cannot be undone; you would pair again to play.")
        }
    }
}


/// "What has to be switched on" in the plainest words we can manage. One line per case, the
/// same four cases every time: PlayStation or computer, at home or away.
struct WhatMustBeOnCard: View {
    @EnvironmentObject private var model: AppModel

    private var showComputer: Bool { model.showKindPicker || model.consoles.contains { $0.kind == .computer } }

    var body: some View {
        Card {
            Text("WHAT HAS TO BE ON").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            row("PlayStation 5 · at home", "Your PS5 switched on. That's all.", "house.fill")
            row("PlayStation 5 · away from home", "Your PS5 switched on at home, and your router set up once.", "antenna.radiowaves.left.and.right")
            if showComputer {
                row("Computer · at home", "Computer on and awake, with the CoastPlay Host app open.", "house.fill")
                row("Computer · away from home", "The same: computer on and awake, CoastPlay Host open. Plus your router set up once.", "antenna.radiowaves.left.and.right")
                Text("A computer always needs CoastPlay Host open, on Wi-Fi and on mobile data. If it is closed, or the computer is asleep or off, this phone cannot reach it and cannot wake it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Rest mode on the PS5 is meant to work too, but we are still testing it. If it won't connect, switch the PS5 fully on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("whatMustBeOn")
    }

    private func row(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
