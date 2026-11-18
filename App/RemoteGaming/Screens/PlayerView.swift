import SwiftUI
import RGPCore

struct PlayerView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var controllers: GameControllerProvider
    @Environment(\.dismiss) private var dismiss
    /// Off by default: the picture stays clear. Turned on in Settings → Advanced.
    @AppStorage("showDiagnostics") private var showDiagnostics = false
    @State private var pointerDown = false
    /// Tap the picture to hide or show the bar. It is always shown when not playing.
    @State private var barHidden = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The person's saved choice for on-screen controls.
    @AppStorage("touchControls") private var touchControlsPref = false
    /// Shown now. Starts from the saved choice, or on when no controller is connected.
    @State private var touchControls = false
    /// On-screen state, kept only so the demo pattern can react to it.
    @State private var touchState = ControllerState.neutral

    /// What the app asked the console for, shown beside what is actually arriving.
    private var requestedText: String {
        let base = model.streamConfig
        let c = session.isLocalRoute ? base : base.forAway
        let rate = c.requestedBitrateKbps.map { "\($0 / 1000) Mbps" } ?? "automatic rate"
        return "\(c.height)p, \(c.fps) fps, \(rate)"
    }

    // Zoom: pinch on a console picture, or the magnifier button. 1 = whole picture.
    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    /// Where a zoomed computer picture is centred: the last place the pointer touched.
    @State private var zoomAnchor: UnitPoint = .center
    @State private var lastPointer: UnitPoint = .center
    @State private var showKeyboard = false
    @State private var promptHidden = false
    @AppStorage("creatorMode") private var creatorMode = false
    @State private var showCreator = false
    @ObservedObject private var creator = CreatorHub.shared
    /// Computer sessions: controller as game keys (W-A-S-D, mouse look) or as a mouse.
    @AppStorage("computerGameKeys") private var gameKeys = false

    private var isComputer: Bool { session.console?.kind == .computer }

    private func setZoom(_ value: CGFloat) {
        zoom = min(4, max(1, value)); zoomBase = zoom
        if zoom == 1 { pan = .zero; panBase = .zero }
    }

    private var zoomGestures: some Gesture {
        MagnificationGesture()
            .onChanged { zoom = min(4, max(1, zoomBase * $0)) }
            .onEnded { _ in setZoom(zoom) }
            .simultaneously(with: DragGesture(minimumDistance: 12)
                .onChanged { value in
                    guard zoom > 1 else { return }
                    pan = CGSize(width: panBase.width + value.translation.width, height: panBase.height + value.translation.height)
                }
                .onEnded { _ in panBase = pan })
    }

    private var touchAllowed: Bool { session.state == .playing && session.console?.kind != .computer }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            surface
                .aspectRatio(videoAspect, contentMode: .fit)
                .scaleEffect(zoom, anchor: isComputer ? zoomAnchor : .center)
                .offset(pan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            // A tap on the picture hides or shows the controls. Computer sessions use touches as the
            // pointer, so they get a small handle instead.
            if touchAllowed, touchControls {
                TouchControlsView(onChange: { state in
                    model.touchInput(state)
                    if session.isDemoSession { touchState = state }
                }, onBackgroundTap: { withAnimation(.easeInOut(duration: 0.15)) { barHidden.toggle() } })
                .ignoresSafeArea()
            } else if session.state == .playing, session.console?.kind != .computer {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { barHidden.toggle() } }
                    .simultaneousGesture(zoomGestures)
                    .accessibilityLabel(barHidden ? "Show controls" : "Hide controls")
                    .accessibilityIdentifier("tapToToggle")
            }
            stateOverlay
            VStack {
                if !barHidden || session.state != .playing {
                    topBar
                } else if session.console?.kind == .computer {
                    Button { barHidden = false } label: {
                        Image(systemName: "chevron.compact.down").font(.title2).padding(.horizontal, 24).padding(.vertical, 2)
                            .background(.black.opacity(0.4), in: Capsule()).foregroundStyle(.white.opacity(0.8))
                    }
                    .accessibilityLabel("Show controls")
                }
                if session.state == .playing, session.isMuted {
                    Label("Sound is muted. Tap the red speaker to turn it back on.", systemImage: "speaker.slash.fill")
                        .font(.footnote.weight(.semibold)).padding(8)
                        .background(Theme.bad.opacity(0.9), in: Capsule()).foregroundStyle(.white)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("mutedNotice")
                }
                Spacer()
                if showKeyboard, session.state == .playing, isComputer {
                    KeyboardBar(sendText: { session.send(text: $0) }, sendKey: { session.send(key: $0) }, onHide: { showKeyboard = false })
                }
                HStack(alignment: .bottom) {
                    if showDiagnostics, session.state == .playing { DiagnosticsOverlay(stats: session.stats, requested: requestedText) }
                    Spacer()
                    inputQuestion
                }
            }
            .padding(12)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showCreator) { CreatorPanel(obs: model.obs).environmentObject(model).environmentObject(session) }
        .onAppear { touchControls = touchControlsPref || controllers.active == nil }
        // Tell the computer which mode this phone last used, as soon as the session is live.
        .onChange(of: session.state) { _, state in if state == .playing, isComputer { session.setGameKeys(gameKeys) } }
        .onChange(of: touchControls) { _, on in if !on { model.touchInput(.neutral); touchState = .neutral } }
        .onDisappear { model.touchInput(.neutral) }
    }

    /// The playback area. A real stream will render decoded video here. In demo mode it shows
    /// a generated test pattern that is watermarked so it can never pass for console video.
    @ViewBuilder private var surface: some View {
        if session.state == .playing, session.isDemoSession {
            DemoSignalView(input: InputMixer.merge(controllers.state, touchState))
        } else if session.state == .playing {
            VideoSurfaceView(destination: model.display)
                .overlay { if session.console?.kind == .computer { pointerLayer } }
        } else {
            Rectangle().fill(Color(white: 0.06))
        }
    }

    /// Shape of the incoming picture, so touches map onto it exactly. 16:9 until the stream reports its size.
    private var videoAspect: CGFloat {
        if let w = session.stats?.width, let h = session.stats?.height, w > 0, h > 0 { return CGFloat(w) / CGFloat(h) }
        return 16.0 / 9.0
    }

    /// Computer sessions only: a finger on the picture is the pointer; touching down presses the button.
    private var pointerLayer: some View {
        GeometryReader { geo in
            // A ring under the finger, drawn on the phone at once. The computer's own pointer
            // arrives with the picture, a moment later; without this it looks like it is lagging
            // or somewhere else.
            if pointerDown {
                Circle().stroke(.white.opacity(0.9), lineWidth: 2).background(Circle().fill(Theme.accent.opacity(0.25)))
                    .frame(width: 26 / max(zoom, 1), height: 26 / max(zoom, 1))
                    .position(x: lastPointer.x * geo.size.width, y: lastPointer.y * geo.size.height)
                    .allowsHitTesting(false)
            }
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let x = Float(min(1, max(0, value.location.x / max(1, geo.size.width))))
                        let y = Float(min(1, max(0, value.location.y / max(1, geo.size.height))))
                        lastPointer = UnitPoint(x: CGFloat(x), y: CGFloat(y))
                        if !pointerDown {
                            pointerDown = true
                            session.send(pointer: PointerEvent(x: x, y: y, phase: .move))
                            session.send(pointer: PointerEvent(x: x, y: y, phase: .down))
                        } else {
                            session.send(pointer: PointerEvent(x: x, y: y, phase: .move))
                        }
                    }
                    .onEnded { value in
                        let x = Float(min(1, max(0, value.location.x / max(1, geo.size.width))))
                        let y = Float(min(1, max(0, value.location.y / max(1, geo.size.height))))
                        pointerDown = false
                        lastPointer = UnitPoint(x: CGFloat(x), y: CGFloat(y))
                        session.send(pointer: PointerEvent(x: x, y: y, phase: .up))
                    })
        }
    }

    /// One row when everything fits; otherwise status and Disconnect stay on the first row and
    /// the tool buttons drop to a second, so Disconnect can never be pushed off the screen.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { barStatus; Spacer(minLength: 8); barTools; barDisconnect }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) { barStatus; Spacer(minLength: 8); barDisconnect }
                ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 8) { barTools } }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var barStatus: some View {
            pill(session.state.label, color: stateColor, id: "statePill")
            if session.isDemoSession { pill("DEMO", color: Theme.demo, id: "demoPill") }
            pill(verticalSizeClass == .regular ? (controllers.active != nil ? "On" : (touchControls ? "Touch" : "None")) : (controllers.active?.name ?? (touchControls ? "On-screen controls" : "No controller")),
                 color: controllers.active != nil || touchControls ? Theme.good : Theme.bad, icon: "gamecontroller.fill", id: "controllerPill")
    }

    @ViewBuilder private var barTools: some View {
            if session.state == .playing, session.console?.kind == .computer {
                barButton("chevron.compact.up", label: "Hide controls") { barHidden = true }
            }
            if touchAllowed {
                Button { touchControls.toggle(); touchControlsPref = touchControls } label: {
                    Image(systemName: touchControls ? "hand.tap.fill" : "hand.tap").font(.footnote.weight(.semibold)).frame(width: 34, height: 34)
                        .background(touchControls ? Theme.accent.opacity(0.9) : .black.opacity(0.65), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel(touchControls ? "Hide on-screen controls" : "Show on-screen controls")
                .accessibilityIdentifier("touchControlsButton")
            }
            if session.state == .playing {
                Button {
                    // Steps through 1×, 1.5×, 2×, 3×, then back. A computer picture zooms in on
                    // the last place you touched; a console picture can also be pinched and dragged.
                    let steps: [CGFloat] = [1, 1.5, 2, 3]
                    let next = steps.first { $0 > zoom + 0.01 } ?? 1
                    if isComputer { zoomAnchor = lastPointer }
                    withAnimation(.easeInOut(duration: 0.15)) { setZoom(next) }
                } label: {
                    Group {
                        if zoom > 1.01 { Text(String(format: zoom == zoom.rounded() ? "%.0f×" : "%.1f×", zoom)).font(.caption.weight(.heavy)) }
                        else { Image(systemName: "plus.magnifyingglass").font(.footnote.weight(.semibold)) }
                    }
                    .frame(width: 34, height: 34)
                    .background(zoom > 1.01 ? Theme.accent.opacity(0.9) : .black.opacity(0.65), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel("Zoom")
                .accessibilityIdentifier("zoomButton")
            }
            if session.state == .playing, isComputer {
                Button { gameKeys.toggle(); session.setGameKeys(gameKeys) } label: {
                    // Says what the controller does right now, and that tapping switches it. It is a
                    // switch, not a status light, so it is never lit up.
                    HStack(spacing: 4) {
                        Image(systemName: gameKeys ? "gamecontroller" : "cursorarrow")
                        Text(gameKeys ? "Controller: game" : "Controller: mouse").lineLimit(1)
                        Image(systemName: "arrow.left.arrow.right").font(.caption2)
                    }
                    .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(height: 34)
                    .background(.black.opacity(0.65), in: Capsule()).overlay(Capsule().stroke(.white.opacity(0.35)))
                    .foregroundStyle(.white)
                }
                .accessibilityLabel(gameKeys ? "Controller sends game keys. Tap for mouse" : "Controller acts as a mouse. Tap for game keys")
                .accessibilityIdentifier("gameKeysButton")
            }
            if session.state == .playing, isComputer {
                Button { showKeyboard.toggle() } label: {
                    Image(systemName: showKeyboard ? "keyboard.chevron.compact.down" : "keyboard").font(.footnote.weight(.semibold)).frame(width: 34, height: 34)
                        .background(showKeyboard ? Theme.accent.opacity(0.9) : .black.opacity(0.65), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel(showKeyboard ? "Hide keyboard" : "Show keyboard")
                .accessibilityIdentifier("keyboardButton")
            }
            if creatorMode {
                // Shows what viewers are getting at a glance; red while a privacy scene is up.
                Button { showCreator = true } label: {
                    Image(systemName: creator.recording ? "record.circle.fill" : "video.fill").font(.footnote.weight(.semibold)).frame(width: 34, height: 34)
                        .background(creator.effectiveScene == .gameplay ? (creator.recording ? Theme.bad.opacity(0.9) : .black.opacity(0.65)) : Theme.demo.opacity(0.95), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel("Creator controls. Viewers see \(creator.effectiveScene.title)")
                .accessibilityIdentifier("creatorButton")
            }
            Button { session.isMuted.toggle() } label: {
                Image(systemName: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.footnote.weight(.semibold)).frame(width: 34, height: 34)
                    .background(session.isMuted ? Theme.bad.opacity(0.9) : .black.opacity(0.65), in: Circle()).foregroundStyle(.white)
            }
            .accessibilityLabel(session.isMuted ? "Sound is muted. Tap to unmute" : "Mute")
            .accessibilityIdentifier("muteButton")
            if session.state == .playing, session.console?.kind == .ps5 {
                // iOS keeps the controller's PS button for itself, so offer it on screen.
                Button { pressConsoleButton(.ps) } label: {
                    Text("PS").font(.footnote.weight(.heavy)).frame(width: 34, height: 34)
                        .background(.black.opacity(0.65), in: Circle()).foregroundStyle(.white)
                }
                .accessibilityLabel("PS button")
                .accessibilityIdentifier("psButton")
            }
    }

    @ViewBuilder private var barDisconnect: some View {
            Button { close() } label: {
                Group {
                    if verticalSizeClass == .regular {          // portrait phone: keep the bar on one line
                        Image(systemName: "xmark").accessibilityLabel("Disconnect")
                    } else {
                        Label("Disconnect", systemImage: "xmark").lineLimit(1).fixedSize()
                    }
                }
                .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.bad.opacity(0.85), in: Capsule()).foregroundStyle(.white)
            }
            .accessibilityIdentifier("disconnectButton")
    }

    private func pill(_ text: String, color: Color, icon: String? = nil, id: String) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) } else { Circle().fill(color).frame(width: 8, height: 8) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.black.opacity(0.65), in: Capsule())
        .foregroundStyle(icon == nil ? .white : color)
        .accessibilityIdentifier(id)
    }

    private func barButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.footnote.weight(.semibold)).frame(width: 34, height: 34)
                .background(.black.opacity(0.65), in: Circle()).foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }

    private var stateColor: Color {
        switch session.state {
        case .playing: return Theme.good
        case .connecting, .reconnecting, .interrupted: return Theme.demo
        case .failed: return Theme.bad
        case .idle, .disconnected: return .gray
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        switch session.state {
        case .connecting:
            progress(session.progressText ?? "Connecting to \(session.console?.name ?? "console")…")
        case .interrupted(let reason):
            progress("Connection interrupted — \(reason)")
        case .reconnecting(let attempt, let max):
            progress("Reconnecting… attempt \(attempt) of \(max)")
        case .failed(let failure):
            VStack(spacing: 12) {
                FailureCard(failure: failure)
                HStack {
                    if failure.canRetry, let console = session.console {
                        Button("Try again") { model.play(console) }.buttonStyle(.borderedProminent)
                    }
                    Button("Close") { dismiss() }.buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 460).padding()
        case .disconnected, .idle:
            VStack(spacing: 12) {
                Text("Session ended").font(.headline)
                Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case .playing:
            if session.stats?.isUnstable == true {
                // A measured fact about the network path, shown so the person doesn't blame the game.
                Label("This network is unstable right now. A different network may play better.", systemImage: "wifi.exclamationmark")
                    .font(.footnote.weight(.semibold)).padding(10)
                    .background(Theme.demo.opacity(0.92), in: Capsule()).foregroundStyle(.black)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("unstableNetworkNotice")
            }
            if controllers.active == nil, !touchControls {
                Label("No controller connected. Connect one, or tap the hand button for on-screen controls.", systemImage: "gamecontroller")
                    .font(.footnote.weight(.semibold)).padding(10)
                    .background(Theme.bad.opacity(0.9), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).font(.headline).multilineTextAlignment(.center)
        }
        .padding(24).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
    }

    private func pressConsoleButton(_ button: ControllerButtons) {
        var pressed = controllers.state
        pressed.buttons.insert(button)
        session.send(pressed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { session.send(controllers.state) }
    }

    /// Asked once per console, after the person has actually used the controller in a real session.
    @ViewBuilder private var inputQuestion: some View {
        if session.state == .playing, !session.isDemoSession, let console = session.console,
           let record = model.readiness[console.id], record.inputSentAt != nil, record.inputConfirmedByUser == nil {
            if !promptHidden {
                HStack(spacing: 10) {
                    Text("Did the \(isComputer ? "computer" : "console") respond to your controller?").font(.footnote.weight(.semibold))
                    Button("Yes") { model.confirmInput(true, for: console) }.buttonStyle(.borderedProminent).controlSize(.small)
                    Button("No") { model.confirmInput(false, for: console) }.buttonStyle(.bordered).controlSize(.small)
                    promptClose
                }
                .padding(10).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("inputQuestion")
            }
        } else if session.state == .playing, let console = session.console, model.readiness[console.id]?.inputConfirmedByUser == false {
            // A reminder, not a fixture: it can be closed, and it leaves by itself after 12 seconds
            // so it never sits over the game.
            if !promptHidden {
                HStack(alignment: .top, spacing: 10) {
                    Text("Controller not reaching the \(isComputer ? "computer" : "console")? Make sure it is connected to this device, then press a button.")
                        .font(.footnote)
                    promptClose
                }
                .padding(10).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .task { try? await Task.sleep(nanoseconds: 12_000_000_000); withAnimation { promptHidden = true } }
            }
        }
    }

    private var promptClose: some View {
        Button { withAnimation { promptHidden = true } } label: {
            Image(systemName: "xmark").font(.caption.weight(.bold)).frame(width: 26, height: 26)
                .background(.white.opacity(0.18), in: Circle()).foregroundStyle(.white)
        }
        .accessibilityLabel("Close this message")
        .accessibilityIdentifier("promptClose")
    }

    private func close() {
        // Leave the screen even if closing the connection is slow: the button must always work.
        Task {
            await session.disconnect()
            dismiss()
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            dismiss()
        }
    }
}

/// Compact overlay of measurements the transport actually reported. Missing values show "—".
struct DiagnosticsOverlay: View {
    let stats: StreamStats?
    var requested: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if stats?.isSimulated == true {
                Text("SIMULATED VALUES").font(.caption2.weight(.heavy)).foregroundStyle(Theme.demo)
            }
            if let requested { row("Asked for", requested) }
            row("Resolution", stats.flatMap { s in s.width.flatMap { w in s.height.map { "\(w)×\($0)" } } })
            row("Frame rate", stats?.framesPerSecond.map { String(format: "%.0f fps", $0) })
            row("Bitrate", stats?.bitrateKbps.map { String(format: "%.1f Mbps", $0 / 1000) })
            row("Packet loss", stats?.packetLossPercent.map { String(format: "%.1f %%", $0) })
            row("Network round-trip", stats?.roundTripMs.map { String(format: "%.0f ms", $0) })
            Text("Round-trip is network only, not input-to-display latency.").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .font(.caption2.monospacedDigit())
        .padding(8)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("diagnostics")
    }

    private func row(_ name: String, _ value: String?) -> some View {
        HStack(spacing: 10) {
            Text(name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value ?? "—")
        }
    }
}

/// Generated test pattern for demo mode. Reacts to controller input so the input path can be
/// seen working, and carries a permanent watermark.
struct DemoSignalView: View {
    let input: ControllerState

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let bars: [Color] = [.white, .yellow, .cyan, .green, .purple, .red, .blue]
                let w = size.width / CGFloat(bars.count)
                for (i, color) in bars.enumerated() {
                    context.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: size.height)),
                                 with: .color(color.opacity(0.28)))
                }
                let sweep = CGFloat(t.truncatingRemainder(dividingBy: 4) / 4) * size.width
                context.fill(Path(CGRect(x: sweep, y: 0, width: 3, height: size.height)), with: .color(.white.opacity(0.7)))
                let cx = size.width / 2 + CGFloat(input.leftX) * size.width * 0.3
                let cy = size.height / 2 - CGFloat(input.leftY) * size.height * 0.3
                let r: CGFloat = input.buttons.isEmpty ? 14 : 26
                context.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)), with: .color(Theme.accent))
            }
        }
        .overlay {
            VStack(spacing: 6) {
                Text("DEMO SIGNAL").font(.system(size: 34, weight: .black))
                Text("Simulated test pattern — this is not video from a console").font(.footnote.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(14).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("demoWatermark")
        }
    }
}


/// Typing for computer sessions: a text box that sends each character as it is typed, plus the
/// keys a phone keyboard doesn't have.
struct KeyboardBar: View {
    let sendText: (String) -> Void
    let sendKey: (SpecialKey) -> Void
    var onHide: () -> Void = {}
    @State private var buffer = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { onHide() } label: {
                    Label("Hide", systemImage: "keyboard.chevron.compact.down").font(.footnote.weight(.semibold))
                        .padding(.vertical, 6).padding(.horizontal, 8)
                        .background(Theme.accent.opacity(0.9), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
                }
                .accessibilityIdentifier("keyboardHide")
                key("esc", .escape); key("tab", .tab)
                key("←", .left); key("↑", .up); key("↓", .down); key("→", .right)
                key("⌫", .delete); key("return", .returnKey)
            }
            TextField("Type here; it appears on the computer", text: $buffer)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.return)
                .focused($focused)
                .padding(8).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .accessibilityIdentifier("keyboardField")
                .onChange(of: buffer) { old, new in
                    // Send only what changed, so corrections on the phone reach the computer too.
                    let common = zip(old, new).prefix { $0 == $1 }.count
                    for _ in 0..<(old.count - common) { sendKey(.delete) }
                    let added = String(new.dropFirst(common))
                    if !added.isEmpty { sendText(added) }
                    if new.count > 60 { buffer = "" }      // keep the box short; nothing is re-sent
                }
                .onSubmit { sendKey(.returnKey); buffer = ""; focused = true }
        }
        .padding(8).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true }
    }

    private func key(_ label: String, _ key: SpecialKey) -> some View {
        Button { sendKey(key) } label: {
            Text(label).font(.footnote.weight(.semibold)).frame(minWidth: 30).padding(.vertical, 6).padding(.horizontal, 6)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white)
        }
    }
}
