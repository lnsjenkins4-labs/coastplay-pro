import SwiftUI
import RGPCore

/// The creator's private control panel. Nothing on this screen is ever part of a public
/// output: the audience feed is built separately from gameplay pictures and scene cards.
struct CreatorPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: SessionController
    @ObservedObject private var hub = CreatorHub.shared
    @ObservedObject private var obs: OBSRemote
    @AppStorage("creatorMode") private var creatorMode = false
    @AppStorage("creatorFeedAddress") private var feedAddress = ""
    @AppStorage("creatorFeedKbps") private var feedKbps = 4500
    @AppStorage("obsAddress") private var obsAddress = ""
    @State private var obsPassword = ""
    @Environment(\.dismiss) private var dismiss

    init(obs: OBSRemote) { self.obs = obs }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Creator Mode", isOn: $creatorMode)
                } footer: {
                    Text("Adds a clean audience feed, recording and replays. It uses more battery, so it is off unless you turn it on. Takes effect the next time you connect.")
                }
                if creatorMode {
                    audience
                    outputs
                    recordingSection
                    clipsSection
                    obsSection
                    healthSection
                }
            }
            .navigationTitle("Creator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Creator", isPresented: Binding(get: { hub.notice != nil }, set: { if !$0 { hub.notice = nil } })) {
                Button("OK") { hub.notice = nil }
            } message: { Text(hub.notice ?? "") }
            .onAppear {
                if let saved = try? model.credentials.load(for: OBSRemote.keychainID) { obsPassword = String(decoding: saved.data, as: UTF8.self) }
            }
        }
    }

    // MARK: Audience feed

    private var audience: some View {
        Section {
            HStack {
                Text("Viewers see")
                Spacer()
                Text(hub.effectiveScene.title).fontWeight(.semibold)
                    .foregroundStyle(hub.effectiveScene == .gameplay ? Theme.good : Theme.demo)
            }
            .accessibilityIdentifier("creatorViewersSee")
            Button {
                hub.scene = hub.scene == .beRightBack ? .gameplay : .beRightBack
            } label: {
                Label(hub.scene == .beRightBack ? "Back to gameplay" : "Be right back", systemImage: hub.scene == .beRightBack ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).tint(hub.scene == .beRightBack ? Theme.good : Theme.demo)
            .accessibilityIdentifier("creatorBRB")
            Picker("Scene", selection: $hub.scene) {
                ForEach(PublicScene.allCases.filter { $0 != .reconnecting }, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Silence game sound on these scenes", isOn: $hub.muteGameOnPrivacyScenes)
        } header: { Text("Audience feed") } footer: {
            Text("If the game connection drops, viewers get “Reconnecting” by itself instead of a frozen picture. Camera scenes are not built yet. Your microphone is not part of this feed yet.")
        }
    }

    // MARK: Outputs

    private var outputs: some View {
        Section {
            HStack {
                Label("External display", systemImage: "tv")
                Spacer()
                Text(hub.externalConnected ? "Showing clean output" : "Not connected").foregroundStyle(hub.externalConnected ? Theme.good : .secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Network feed", systemImage: "dot.radiowaves.left.and.right")
                    Spacer()
                    Text(feedText).foregroundStyle(feedColor)
                }
                TextField("Computer address, e.g. 192.168.1.20:9710", text: $feedAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                Picker("Feed quality", selection: $feedKbps) {
                    Text("2.5 Mbps").tag(2500); Text("4.5 Mbps").tag(4500); Text("8 Mbps").tag(8000)
                }
                .onChange(of: feedKbps) { _, value in hub.setFeedBitrate(kbps: value) }
                Button(hub.feedState == .off ? "Start sending" : "Stop sending") {
                    if hub.feedState == .off { hub.setFeedBitrate(kbps: feedKbps); hub.startFeed(to: feedAddress) } else { hub.stopFeed() }
                }
                .accessibilityIdentifier("creatorFeedToggle")
            }
        } header: { Text("Send gameplay to OBS") } footer: {
            Text("The phone sends straight to your computer on the same network. The phone cannot tell whether OBS received it: check the picture in OBS. Feed quality is separate from the game's own quality.")
        }
    }

    private var feedText: String {
        switch hub.feedState {
        case .off: return "Off"
        case .live: return "Sending"
        case .waiting(let text), .failed(let text): return text
        }
    }
    private var feedColor: Color {
        switch hub.feedState {
        case .live: return Theme.good
        case .failed: return Theme.bad
        default: return .secondary
        }
    }

    // MARK: Recording and replays

    private var recordingSection: some View {
        Section {
            Button {
                hub.recording ? hub.stopRecording() : hub.startRecording()
            } label: {
                Label(hub.recording ? "Stop recording (\(Self.clock(hub.recordingSeconds)))" : "Record clean gameplay",
                      systemImage: hub.recording ? "stop.circle.fill" : "record.circle")
            }
            .tint(hub.recording ? Theme.bad : Theme.accent)
            .accessibilityIdentifier("creatorRecord")
            if hub.recording {
                Button { hub.markHighlight() } label: { Label("Mark a highlight (\(hub.markers.count) so far)", systemImage: "flag.fill") }
            }
            Toggle("Instant replay (keeps the last minute)", isOn: $hub.replayOn)
            if hub.replayOn {
                HStack {
                    Button("Save last 30 s") { hub.saveReplay(seconds: 30) }.buttonStyle(.bordered)
                    Button("Save last 60 s") { hub.saveReplay(seconds: 60) }.buttonStyle(.bordered)
                    Spacer()
                    Text("\(Int(hub.replaySeconds)) s held").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: { Text("Record and save moments") } footer: {
            Text("Saved on this phone only. Recordings and replays are clean gameplay with game sound, without the scene cards, your voice or anything from the app's screens.")
        }
    }

    private var clipsSection: some View {
        Section("Saved clips") {
            if hub.clips.isEmpty { Text("Nothing saved yet.").foregroundStyle(.secondary) }
            ForEach(hub.clips, id: \.self) { clip in
                VStack(alignment: .leading, spacing: 6) {
                    Text(clip.deletingPathExtension().lastPathComponent).font(.subheadline)
                    HStack {
                        ShareLink(item: clip) { Label("Share or save", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                        let marks = hub.markers(for: clip)
                        if !marks.isEmpty {
                            Menu("Highlights (\(marks.count))") {
                                ForEach(Array(marks.enumerated()), id: \.offset) { index, marker in
                                    Button("Cut 30 s before \(Self.clock(marker.seconds))") { hub.exportHighlight(from: clip, marker: marker, length: 30) { _ in } }
                                    if index == marks.count - 1 { EmptyView() }
                                }
                            }
                        }
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { hub.delete(clip) } }
            }
        }
    }

    // MARK: OBS remote control

    private var obsSection: some View {
        Section {
            HStack {
                Label("OBS remote", systemImage: "slider.horizontal.3")
                Spacer()
                Text(obs.state.text).foregroundStyle(obs.state.isLive ? Theme.good : .secondary)
            }
            if !obs.state.isLive {
                TextField("OBS address, e.g. 192.168.1.20:4455", text: $obsAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                SecureField("OBS WebSocket password", text: $obsPassword)
                Button("Connect to OBS") {
                    try? model.credentials.save(PairingSecret(data: Data(obsPassword.utf8)), for: OBSRemote.keychainID)
                    obs.connect(address: obsAddress, password: obsPassword)
                }
            } else {
                HStack {
                    statusChip("Recording", obs.isRecording)
                    statusChip("Live", obs.isStreaming)
                    statusChip("Replay buffer", obs.replayBufferOn)
                }
                Button(obs.isRecording == true ? "Stop OBS recording" : "Start OBS recording") { obs.toggleRecording() }
                Button("Save OBS replay") { obs.saveReplay() }.disabled(obs.replayBufferOn != true)
                Button(obs.currentScene != nil && obs.currentScene == obs.brbScene ? "Back from BRB in OBS" : "BRB in OBS") { obs.toggleBRB() }
                Picker("OBS scene", selection: Binding(get: { obs.currentScene ?? "" }, set: { obs.setScene($0) })) {
                    ForEach(obs.scenes, id: \.self) { Text($0).tag($0) }
                }
                ForEach(obs.inputs, id: \.self) { input in
                    Button { obs.toggleMute(input) } label: {
                        Label(input, systemImage: obs.muted.contains(input) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .tint(obs.muted.contains(input) ? Theme.bad : Theme.accent)
                }
                Button("Disconnect from OBS", role: .destructive) { obs.disconnect() }
            }
            if let message = obs.lastMessage { Text(message).font(.footnote).foregroundStyle(.secondary) }
        } header: { Text("Control OBS") } footer: {
            Text("This controls OBS only. It does not carry picture or sound, so “connected” here does not mean gameplay is reaching OBS. Going live is done in OBS, not from here.")
        }
    }

    private func statusChip(_ name: String, _ on: Bool?) -> some View {
        Text("\(name): \(on.map { $0 ? "on" : "off" } ?? "—")").font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((on == true ? Theme.good : Color.gray).opacity(0.25), in: Capsule())
    }

    // MARK: Health

    private var healthSection: some View {
        Section {
            row("Game → phone", session.state == .playing ? "Playing" : "Not playing")
            row("Game picture", session.stats?.framesPerSecond.map { String(format: "%.0f a second", $0) })
            row("Game data rate", session.stats?.bitrateKbps.map { String(format: "%.1f Mbps", $0 / 1000) })
            row("Pictures for creator outputs", hub.health.incomingFps > 0 ? String(format: "%.0f a second", hub.health.incomingFps) : nil)
            row("Phone → computer", feedText)
            row("Feed data rate", hub.feedState == .live ? String(format: "%.1f Mbps, %.0f pictures a second", hub.health.feedKbps / 1000, hub.health.feedFps) : nil)
            row("Free storage", hub.health.freeGB.map { String(format: "%.1f GB", $0) })
            row("Phone temperature", hub.health.thermal)
            row("Battery", hub.health.batteryPercent.map { "\($0)%" })
        } header: { Text("Health") } footer: {
            Text("Two separate links: the game coming in, and the feed going out. “—” means that figure is not being measured right now.")
        }
    }

    private func row(_ name: String, _ value: String?) -> some View {
        HStack { Text(name); Spacer(); Text(value ?? "—").foregroundStyle(.secondary) }
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
