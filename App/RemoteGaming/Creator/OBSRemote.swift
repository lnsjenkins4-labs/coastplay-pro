import Foundation
import RGPCore

/// Remote control for OBS on the creator's computer, over OBS's built-in WebSocket server.
/// Control only: this link carries no picture or sound. The password is kept in the Keychain
/// and is never written to a log.
@MainActor
final class OBSRemote: ObservableObject {
    @Published private(set) var state: CreatorLinkState = .off
    @Published private(set) var scenes: [String] = []
    @Published private(set) var currentScene: String?
    @Published private(set) var isRecording: Bool?
    @Published private(set) var isStreaming: Bool?
    @Published private(set) var replayBufferOn: Bool?
    @Published private(set) var inputs: [String] = []
    @Published private(set) var muted: Set<String> = []
    @Published var lastMessage: String?

    private var task: URLSessionWebSocketTask?
    private var password = ""
    private var counter = 0
    private var sceneBeforeBRB: String?
    static let keychainID = "obs-websocket"

    /// `address` like "192.168.1.20:4455" (OBS → Tools → WebSocket Server Settings).
    func connect(address: String, password: String) {
        disconnect()
        guard let url = URL(string: "ws://\(address.trimmingCharacters(in: .whitespaces))"), url.host != nil else {
            state = .failed("Type the address like 192.168.1.20:4455."); return
        }
        self.password = password
        state = .waiting("Connecting…")
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive(on: task)
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .off; scenes = []; currentScene = nil; isRecording = nil; isStreaming = nil; replayBufferOn = nil; inputs = []; muted = []
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === task else { return }
                switch result {
                case .failure(let error):
                    self.task = nil
                    self.state = .failed("OBS did not answer (\(error.localizedDescription)).")
                case .success(let message):
                    if case .string(let text) = message { self.handle(OBSProtocol.parse(text)) }
                    self.receive(on: task)
                }
            }
        }
    }

    private func send(_ data: Data) {
        task?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func request(_ type: String, _ data: [String: Any] = [:]) {
        guard state.isLive || type.hasPrefix("Get") else { return }
        counter += 1
        send(OBSProtocol.request(type, id: "\(counter)", data: data))
    }

    private func handle(_ incoming: OBSProtocol.Incoming) {
        switch incoming {
        case .hello(let salt, let challenge):
            if let salt, let challenge {
                guard !password.isEmpty else { state = .failed("OBS asks for a password. Type the one from its WebSocket settings."); return }
                send(OBSProtocol.identify(authentication: OBSProtocol.authentication(password: password, salt: salt, challenge: challenge)))
            } else {
                send(OBSProtocol.identify(authentication: nil))
            }
        case .identified:
            state = .live
            refresh()
        case .event(let type, let data):
            switch type {
            case "CurrentProgramSceneChanged": currentScene = data["sceneName"] as? String
            case "SceneListChanged": request("GetSceneList")
            case "RecordStateChanged": isRecording = data["outputActive"] as? Bool
            case "StreamStateChanged": isStreaming = data["outputActive"] as? Bool
            case "ReplayBufferStateChanged": replayBufferOn = data["outputActive"] as? Bool
            case "ReplayBufferSaved": lastMessage = "OBS saved a replay."
            case "InputMuteStateChanged":
                if let name = data["inputName"] as? String { if data["inputMuted"] as? Bool == true { muted.insert(name) } else { muted.remove(name) } }
            default: break
            }
        case .response(let type, _, let ok, let comment, let data):
            guard ok else {
                if type == "SaveReplayBuffer" { lastMessage = "OBS could not save a replay. Turn on its Replay Buffer first." }
                else if !type.hasPrefix("Get") { lastMessage = "OBS refused “\(type)”\(comment.map { ": \($0)" } ?? "")." }
                if type == "GetReplayBufferStatus" { replayBufferOn = nil }
                return
            }
            switch type {
            case "GetSceneList":
                let list = (data["scenes"] as? [[String: Any]] ?? []).sorted { ($0["sceneIndex"] as? Int ?? 0) > ($1["sceneIndex"] as? Int ?? 0) }
                scenes = list.compactMap { $0["sceneName"] as? String }
                currentScene = data["currentProgramSceneName"] as? String
            case "GetRecordStatus": isRecording = data["outputActive"] as? Bool
            case "GetStreamStatus": isStreaming = data["outputActive"] as? Bool
            case "GetReplayBufferStatus": replayBufferOn = data["outputActive"] as? Bool
            case "GetInputList":
                inputs = (data["inputs"] as? [[String: Any]] ?? []).compactMap { $0["inputName"] as? String }
                for name in inputs { request("GetInputMute", ["inputName": name]) }
            case "ToggleInputMute", "StartRecord", "StopRecord": break   // the matching event updates the state
            default: break
            }
        case .unknown: break
        }
    }

    func refresh() {
        for type in ["GetSceneList", "GetRecordStatus", "GetStreamStatus", "GetReplayBufferStatus", "GetInputList"] { request(type) }
    }

    func setScene(_ name: String) { request("SetCurrentProgramScene", ["sceneName": name]) }
    func toggleRecording() { request(isRecording == true ? "StopRecord" : "StartRecord") }
    func saveReplay() { request("SaveReplayBuffer") }
    func toggleMute(_ input: String) { request("ToggleInputMute", ["inputName": input]) }

    /// The OBS scene used for "be right back": the first whose name contains "brb" or "right back".
    var brbScene: String? {
        scenes.first { let n = $0.lowercased(); return n.contains("brb") || n.contains("right back") }
    }

    /// One action: go to the BRB scene, or come back to the scene that was live before it.
    func toggleBRB() {
        guard let brb = brbScene else { lastMessage = "No OBS scene has “BRB” in its name. Add one to use this button."; return }
        if currentScene == brb, let back = sceneBeforeBRB { setScene(back) } else { sceneBeforeBRB = currentScene; setScene(brb) }
    }
}
