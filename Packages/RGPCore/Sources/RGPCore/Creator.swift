import Foundation
import CryptoKit

// MARK: - Creator Mode: scenes

/// What the audience feed shows. The private player view is never one of these.
/// Camera scenes are not listed: they need the camera composition path, which is not built yet.
public enum PublicScene: String, CaseIterable, Sendable, Codable {
    case gameplay, startingSoon, beRightBack, reconnecting, ending

    public var title: String {
        switch self {
        case .gameplay: return "Gameplay"
        case .startingSoon: return "Starting soon"
        case .beRightBack: return "Be right back"
        case .reconnecting: return "Reconnecting"
        case .ending: return "Thanks for watching"
        }
    }

    /// True when the scene replaces the game picture entirely (nothing from the game is shown).
    public var hidesGameplay: Bool { self != .gameplay }

    /// The scene the audience actually gets. A chosen privacy scene always wins. If gameplay is
    /// chosen but no game picture is arriving, the audience gets "Reconnecting" rather than a
    /// frozen picture or, worse, whatever the phone is showing.
    public static func effective(chosen: PublicScene, gameplayArriving: Bool) -> PublicScene {
        if chosen == .gameplay, !gameplayArriving { return .reconnecting }
        return chosen
    }
}

/// The three separate connection questions in Creator Mode. They fail independently and must be
/// reported independently.
public enum CreatorLinkState: Sendable, Equatable {
    case off
    case waiting(String)       // e.g. "Waiting for a starting picture"
    case live
    case failed(String)

    public var isLive: Bool { self == .live }
    public var text: String {
        switch self {
        case .off: return "Off"
        case .waiting(let why): return why
        case .live: return "Live"
        case .failed(let why): return why
        }
    }
}

// MARK: - MPEG transport stream muxer (network feed to OBS)

/// Packs H.264 pictures and AAC sound into an MPEG transport stream, the format OBS's Media
/// Source reads from a network address. Pure data in, data out: no sockets here.
public struct MPEGTSMuxer {
    public static let videoPID: UInt16 = 0x100, audioPID: UInt16 = 0x101, pmtPID: UInt16 = 0x1000
    private var counters: [UInt16: UInt8] = [:]
    public let hasAudio: Bool

    public init(hasAudio: Bool) { self.hasAudio = hasAudio }

    /// Program tables. Send at the start and again at least a few times a second (with keyframes).
    public mutating func tables() -> Data {
        var pat: [UInt8] = [0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01,
                            0xE0 | UInt8(Self.pmtPID >> 8), UInt8(Self.pmtPID & 0xFF)]
        pat += Self.crc(pat)
        var streams: [UInt8] = [0x1B, 0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00]
        if hasAudio { streams += [0x0F, 0xE0 | UInt8(Self.audioPID >> 8), UInt8(Self.audioPID & 0xFF), 0xF0, 0x00] }
        let length = 9 + streams.count + 4
        var pmt: [UInt8] = [0x02, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF), 0x00, 0x01, 0xC1, 0x00, 0x00,
                            0xE0 | UInt8(Self.videoPID >> 8), UInt8(Self.videoPID & 0xFF), 0xF0, 0x00] + streams
        pmt += Self.crc(pmt)
        return section(pid: 0, pat) + section(pid: Self.pmtPID, pmt)
    }

    /// One picture as Annex-B (start codes). `pts90k` is the time in 90 kHz units.
    public mutating func video(annexB: Data, pts90k: UInt64, isKeyframe: Bool) -> Data {
        // An access-unit delimiter first: receivers use it to find picture boundaries.
        let payload = Self.pesHeader(streamID: 0xE0, pts: pts90k, length: 0) + [0, 0, 0, 1, 0x09, 0xF0] + [UInt8](annexB)
        return packets(pid: Self.videoPID, payload: payload, pcr: pts90k, randomAccess: isKeyframe)
    }

    /// One AAC frame with its ADTS header.
    public mutating func audio(adts: Data, pts90k: UInt64) -> Data {
        let payload = Self.pesHeader(streamID: 0xC0, pts: pts90k, length: adts.count + 8) + [UInt8](adts)
        return packets(pid: Self.audioPID, payload: payload, pcr: nil, randomAccess: false)
    }

    /// The 7-byte ADTS header for one AAC-LC frame.
    public static func adtsHeader(frameLength: Int, sampleRate: Int, channels: Int) -> Data {
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]
        let index = UInt8(rates.firstIndex(of: sampleRate) ?? 3)
        let full = frameLength + 7
        return Data([0xFF, 0xF1,
                     (1 << 6) | (index << 2) | UInt8((channels >> 2) & 1),
                     UInt8((channels & 3) << 6) | UInt8((full >> 11) & 3),
                     UInt8((full >> 3) & 0xFF),
                     UInt8((full & 7) << 5) | 0x1F,
                     0xFC])
    }

    private static func pesHeader(streamID: UInt8, pts: UInt64, length: Int) -> [UInt8] {
        let p = pts & 0x1_FFFF_FFFF
        let len = length > 0xFFFF ? 0 : length
        return [0, 0, 1, streamID, UInt8(len >> 8), UInt8(len & 0xFF), 0x80, 0x80, 5,
                0x21 | UInt8((p >> 29) & 0x0E), UInt8((p >> 22) & 0xFF), 0x01 | UInt8((p >> 14) & 0xFE),
                UInt8((p >> 7) & 0xFF), 0x01 | UInt8((p << 1) & 0xFE)]
    }

    private mutating func next(_ pid: UInt16) -> UInt8 {
        let value = counters[pid] ?? 0
        counters[pid] = (value + 1) & 0x0F
        return value
    }

    private mutating func section(pid: UInt16, _ body: [UInt8]) -> Data {
        var packet: [UInt8] = [0x47, 0x40 | UInt8(pid >> 8), UInt8(pid & 0xFF), 0x10 | next(pid), 0x00] + body
        packet += [UInt8](repeating: 0xFF, count: 188 - packet.count)
        return Data(packet)
    }

    private mutating func packets(pid: UInt16, payload: [UInt8], pcr: UInt64?, randomAccess: Bool) -> Data {
        var out = Data(capacity: (payload.count / 184 + 2) * 188)
        var offset = 0, first = true
        while offset < payload.count {
            var field: [UInt8] = []          // adaptation field body (flags and clock reference)
            if first, let pcr {
                let base = pcr & 0x1_FFFF_FFFF
                let flags: UInt8 = randomAccess ? 0x50 : 0x10
                field = [flags, UInt8(base >> 25), UInt8((base >> 17) & 0xFF),
                         UInt8((base >> 9) & 0xFF), UInt8((base >> 1) & 0xFF), UInt8((base & 1) << 7) | 0x7E, 0x00]
            }
            let remaining = payload.count - offset
            var adaptation: [UInt8] = field.isEmpty ? [] : [UInt8(field.count)] + field
            let space = 184 - adaptation.count
            if remaining < space {
                let stuff = space - remaining
                if field.isEmpty {
                    adaptation = stuff == 1 ? [0] : [UInt8(stuff - 1), 0x00] + [UInt8](repeating: 0xFF, count: stuff - 2)
                } else {
                    adaptation = [UInt8(field.count + stuff)] + field + [UInt8](repeating: 0xFF, count: stuff)
                }
            }
            let take = min(remaining, 184 - adaptation.count)
            let start: UInt8 = first ? 0x40 : 0, control: UInt8 = adaptation.isEmpty ? 0x10 : 0x30
            out.append(contentsOf: [0x47, start | UInt8(pid >> 8), UInt8(pid & 0xFF), control | next(pid)])
            out.append(contentsOf: adaptation)
            out.append(contentsOf: payload[offset..<offset + take])
            offset += take; first = false
        }
        return out
    }

    static func crc(_ bytes: [UInt8]) -> [UInt8] {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        }
        return [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }
}

// MARK: - OBS remote control (obs-websocket 5 protocol)

/// Message building and reading for OBS's built-in WebSocket server. This controls OBS; it
/// carries no video or sound. A working control link says nothing about whether gameplay
/// is reaching OBS.
public enum OBSProtocol {
    /// Events we listen for: general, scenes, inputs, outputs.
    public static let eventSubscriptions = 1 | 4 | 8 | 64

    /// The answer to OBS's password challenge. The password itself is never sent.
    public static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    public static func identify(authentication: String?) -> Data {
        var d: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": eventSubscriptions]
        if let authentication { d["authentication"] = authentication }
        return encode(["op": 1, "d": d])
    }

    public static func request(_ type: String, id: String, data: [String: Any] = [:]) -> Data {
        var d: [String: Any] = ["requestType": type, "requestId": id]
        if !data.isEmpty { d["requestData"] = data }
        return encode(["op": 6, "d": d])
    }

    public enum Incoming {
        case hello(salt: String?, challenge: String?)
        case identified
        case event(type: String, data: [String: Any])
        case response(type: String, id: String, ok: Bool, comment: String?, data: [String: Any])
        case unknown
    }

    public static func parse(_ text: String) -> Incoming {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let op = object["op"] as? Int, let d = object["d"] as? [String: Any] else { return .unknown }
        switch op {
        case 0:
            let auth = d["authentication"] as? [String: Any]
            return .hello(salt: auth?["salt"] as? String, challenge: auth?["challenge"] as? String)
        case 2: return .identified
        case 5: return .event(type: d["eventType"] as? String ?? "", data: d["eventData"] as? [String: Any] ?? [:])
        case 7:
            let status = d["requestStatus"] as? [String: Any]
            return .response(type: d["requestType"] as? String ?? "", id: d["requestId"] as? String ?? "",
                             ok: status?["result"] as? Bool ?? false, comment: status?["comment"] as? String,
                             data: d["responseData"] as? [String: Any] ?? [:])
        default: return .unknown
        }
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

// MARK: - Highlight markers

/// A moment the creator flagged during a recording, as seconds from the start of that recording.
public struct HighlightMarker: Codable, Sendable, Equatable {
    public var seconds: Double
    public init(seconds: Double) { self.seconds = seconds }

    /// The stretch of the recording to cut for this marker: `length` seconds ending at the marker.
    public func clipRange(length: Double, recordingDuration: Double) -> ClosedRange<Double> {
        let end = min(max(seconds, 0), recordingDuration)
        return max(0, end - length)...end
    }
}
