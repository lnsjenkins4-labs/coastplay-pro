import Foundation

/// Device compatibility list. A device only becomes `hardwareVerified` after a real
/// interactive console session (video, audio, input) has been run on that physical device
/// and recorded in docs/TEST_CHECKLIST.md. Nothing qualifies yet.
public struct CompatibilityEntry: Identifiable, Sendable {
    public enum Status: String, Sendable {
        case planned = "Planned"
        case experimental = "Experimental"
        case hardwareVerified = "Hardware-verified"
    }
    public var id: String { device }
    public var device: String
    public var method: String
    public var status: Status
    public var note: String

    public static let matrix: [CompatibilityEntry] = [
        .init(device: "iPhone (native app)", method: "Native app, direct connection to console",
              status: .experimental, note: "Private prototype build only: live PS5 video, sound and controller input (cable and Bluetooth) confirmed by the owner on an iPhone 15 Pro over home Wi-Fi. Sign-in and pairing inside the app are confirmed on that phone. Away from home over mobile data works with picture, sound and controller (owner-confirmed, one session), but only after the owner forwarded ports on the home router; it is not yet something a customer could do unaided. Rest-mode wake is unconfirmed. Sound trails the picture by about 0.2 s. The normal app build has no real stream."),
        .init(device: "iPad", method: "Native app", status: .planned, note: "Same app as iPhone; untested."),
        .init(device: "Mac as the source (mirroring)", method: "CoastPlay Host app on the Mac, same network", status: .experimental,
              note: "Our own host app shares the Mac's screen and sound and accepts touch and controller input as mouse and keyboard. Games do not see a real controller. Same network only."),
        .init(device: "Windows PC as the source", method: "Host app for Windows", status: .planned, note: "No Windows host exists yet."),
        .init(device: "Xbox as the source", method: "Undecided", status: .planned,
              note: "Placeholder only. No Xbox connection code exists and nothing has been tested; the owner has no Xbox to test with."),
        .init(device: "Android phone", method: "Native app sharing the protocol core", status: .planned,
              note: "No Android project exists yet."),
        .init(device: "Web browser receiver", method: "Browser playback fed by a bridge", status: .planned,
              note: "Hypothesis only. A browser cannot speak the console protocol directly, so this needs a bridge device."),
        .init(device: "Tesla Model S (2017)", method: "Undecided: in-car browser vs phone/adapter bridge", status: .planned,
              note: "Parked use only. Not tested on the car. Neither display method has been proven."),
        .init(device: "External HDMI/cast adapters", method: "Undecided", status: .planned, note: "Not started."),
    ]
}
