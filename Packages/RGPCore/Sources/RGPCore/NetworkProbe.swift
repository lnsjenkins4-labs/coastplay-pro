import Foundation

/// Measures network round-trip time with a standard ping (ICMP echo), which needs no special
/// permission on Apple platforms. This is network delay only: it does not include the console
/// capturing and compressing a frame, or this device decoding and drawing it.
public enum NetworkProbe {
    /// One ping. Returns milliseconds, or nil if there was no reply (some networks block pings).
    public static func pingMs(host: String, timeout: TimeInterval = 1.0) -> Double? {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // ICMP echo request: type 8, code 0, checksum, identifier, sequence, then 8 bytes of payload.
        let identifier = UInt16.random(in: 1...UInt16.max)
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8
        packet[4] = UInt8(identifier >> 8); packet[5] = UInt8(identifier & 0xFF)
        packet[7] = 1
        var sum: UInt32 = 0
        for i in stride(from: 0, to: packet.count, by: 2) { sum += UInt32(packet[i]) << 8 | UInt32(packet[i + 1]) }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        let checksum = ~UInt16(truncatingIfNeeded: sum)
        packet[2] = UInt8(checksum >> 8); packet[3] = UInt8(checksum & 0xFF)

        let started = Date()
        let sent = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date().timeIntervalSince(started) < timeout {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            // The reply arrives with its IP header in front; find the ICMP part.
            let headerLength = Int(buffer[0] & 0x0F) * 4
            guard count >= headerLength + 8 else { continue }
            let type = buffer[headerLength]
            let replyID = UInt16(buffer[headerLength + 4]) << 8 | UInt16(buffer[headerLength + 5])
            if type == 0, replyID == identifier { return Date().timeIntervalSince(started) * 1000 }
        }
        return nil
    }

    /// Fallback when pings are blocked: how long it takes to open (and immediately close) a TCP
    /// connection. Opening a connection is one round trip, so this approximates the same delay.
    public static func tcpConnectMs(host: String, port: UInt16, timeout: TimeInterval = 2.0) -> Double? {
        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let started = Date()
        let result = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 ? Date().timeIntervalSince(started) * 1000 : nil
    }

    /// The middle value of a few pings, to smooth out one slow reply.
    public static func typicalPingMs(host: String, samples: Int = 3) -> Double? {
        let values = (0..<samples).compactMap { _ in pingMs(host: host) }.sorted()
        return values.isEmpty ? nil : values[values.count / 2]
    }
}
