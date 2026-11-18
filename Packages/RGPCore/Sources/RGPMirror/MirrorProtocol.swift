import Foundation
import Network
import CryptoKit
import RGPCore

/// Wire format for computer mirroring. Our own design, local network only.
///
/// Transport: one TCP connection secured with TLS using a pre-shared key derived from the
/// 8-digit pairing code the host app shows. Without the code the TLS handshake fails, so the
/// stream is both authenticated and encrypted.
///
/// Framing: [type: 1 byte][payload length: 4 bytes big-endian][payload]
public enum MirrorProtocol {
    public static let serviceType = "_rgpmirror._tcp"
    public static let defaultPort: UInt16 = 9311
    public static let maxPayload = 4 * 1024 * 1024
    /// Away-from-home connections use their own port, opened to the internet by a router
    /// forward. It accepts only a long random key (256 bits) that the host hands to a phone
    /// during a home-network session. The 8-digit code is never accepted on this port: eight
    /// digits can be guessed over the internet, a 256-bit key cannot.
    public static let awayPort: UInt16 = 9312
    public static func awaySecret(_ key: String) -> String { "away-v1-" + key }

    public enum MessageType: UInt8 {
        case hello = 1            // host → client, JSON `MirrorHello`
        case video = 2            // host → client, one H.264 access unit, Annex-B
        case audio = 3            // host → client, interleaved signed 16-bit PCM, 48 kHz stereo
        case controller = 16      // client → host, packed `ControllerState`
        case pointer = 17         // client → host, packed `PointerEvent`
        case keyframeRequest = 18 // client → host, empty
        case text = 19            // client → host, UTF-8 text to type (at most 256 bytes)
        case key = 20             // client → host, one byte: `SpecialKey` raw value
        case controllerMode = 21  // client → host, one byte: 0 = mouse (desktop), 1 = game keys
        case videoAck = 22        // client → host, 4 bytes big-endian: how many pictures have arrived
        case awayKey = 23         // host → client, home-network sessions only: the long key for the away port
    }

    public static func frame(_ type: MessageType, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    // MARK: Input packing (little-endian)

    public static func pack(_ state: ControllerState) -> Data {
        var data = Data(capacity: 28)
        var buttons = state.buttons.rawValue.littleEndian
        withUnsafeBytes(of: &buttons) { data.append(contentsOf: $0) }
        for value in [state.leftX, state.leftY, state.rightX, state.rightY, state.l2, state.r2] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpackController(_ data: Data) -> ControllerState? {
        guard data.count == 28 else { return nil }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        var state = ControllerState()
        state.buttons = ControllerButtons(rawValue: u32(0))
        let floats = (0..<6).map { Float(bitPattern: u32(4 + $0 * 4)) }
        guard floats.allSatisfy({ $0.isFinite }) else { return nil }
        state.leftX = floats[0]; state.leftY = floats[1]; state.rightX = floats[2]; state.rightY = floats[3]
        state.l2 = floats[4]; state.r2 = floats[5]
        return state
    }

    public static func pack(_ event: PointerEvent) -> Data {
        var data = Data([event.phase.rawValue])
        for value in [event.x, event.y] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpackPointer(_ data: Data) -> PointerEvent? {
        guard data.count == 9 else { return nil }
        let bytes = [UInt8](data)
        guard let phase = PointerEvent.Phase(rawValue: bytes[0]) else { return nil }
        func f32(_ offset: Int) -> Float {
            Float(bitPattern: UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24)
        }
        let x = f32(1), y = f32(5)
        guard x.isFinite, y.isFinite else { return nil }
        return PointerEvent(x: min(1, max(0, x)), y: min(1, max(0, y)), phase: phase)
    }

    // MARK: Security

    /// Network parameters for both ends. The pairing code never travels over the network.
    public static func parameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data("rgp-mirror-v1".utf8), using: key)
        let psk = Data(code).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("rgp-mirror".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
}

public struct MirrorHello: Codable, Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var canControl: Bool
    public init(name: String, width: Int, height: Int, fps: Int, canControl: Bool) {
        self.name = name; self.width = width; self.height = height; self.fps = fps; self.canControl = canControl
    }
}

/// Reassembles frames from a byte stream. Rejects oversized or unknown frames by reporting
/// `corrupt`, after which the connection should be closed.
public struct MirrorFrameParser {
    private var buffer = Data()
    public private(set) var corrupt = false
    public init() {}

    public mutating func append(_ data: Data) -> [(MirrorProtocol.MessageType, Data)] {
        guard !corrupt else { return [] }
        buffer.append(data)
        var out: [(MirrorProtocol.MessageType, Data)] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16 | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            guard length <= MirrorProtocol.maxPayload, let type = MirrorProtocol.MessageType(rawValue: buffer[start]) else {
                corrupt = true
                buffer.removeAll()
                return out
            }
            guard buffer.count >= 5 + length else { break }
            out.append((type, buffer.subdata(in: (start + 5)..<(start + 5 + length))))
            buffer.removeSubrange(start..<(start + 5 + length))
        }
        return out
    }
}
