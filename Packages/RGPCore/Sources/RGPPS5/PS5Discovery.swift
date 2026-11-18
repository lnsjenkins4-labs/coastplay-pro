import Foundation
import RGPCore

/// PS5 local-network discovery: a small UDP request/response exchange that asks consoles
/// on the LAN to identify themselves. This is the only real PS5 protocol code in the project.
/// It does not pair, authenticate, wake, or stream.
public enum PS5Discovery {
    public static let port: UInt16 = 9302
    public static let protocolVersion = "00030010"

    public static func searchMessage() -> Data {
        Data("SRCH * HTTP/1.1\ndevice-discovery-protocol-version:\(protocolVersion)\n".utf8)
    }

    /// Parses a discovery reply. Returns nil if it is not a recognisable PS5 reply.
    public static func parseResponse(_ data: Data, from address: String) -> DiscoveredConsole? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let statusLine = lines.first, statusLine.hasPrefix("HTTP/1.1 ") else { return nil }
        let statusCode = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let hostID = headers["host-id"], headers["host-type"]?.uppercased() == "PS5" else { return nil }

        let status: DiscoveredConsole.Status
        switch statusCode {
        case 200: status = .ready
        case 620: status = .standby
        default: status = .unknown
        }
        return DiscoveredConsole(id: hostID, name: headers["host-name"] ?? "PS5", kind: .ps5, address: address,
                                 status: status, systemVersion: headers["system-version"])
    }

    public enum ProbeError: Error, CustomStringConvertible {
        case socket(String)
        public var description: String { switch self { case .socket(let m): return m } }
    }

    /// Every usable address on this device's own Wi-Fi/Ethernet network (IPv4, up to 1,022 hosts).
    /// Used to ask each address directly when a broadcast search is not delivered, which happens
    /// on some routers and on iPhones without Apple's multicast permission.
    static func localSubnetHosts() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = entry.pointee.ifa_netmask,
                  String(cString: entry.pointee.ifa_name).hasPrefix("en") else { continue }
            let ip = UInt32(bigEndian: addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let netmask = UInt32(bigEndian: mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr })
            let hostBits = ~netmask
            guard hostBits >= 3, hostBits <= 1023 else { continue }     // skip tiny or very large networks
            let network = ip & netmask
            for host in 1..<hostBits where (network | host) != ip {
                let value = network | host
                result.append("\(value >> 24 & 0xFF).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)")
            }
        }
        return result
    }

    /// Blocking. Asks every address on the local network directly and collects PS5 replies.
    public static func searchSubnet(timeout: TimeInterval = 2.5) throws -> [DiscoveredConsole] {
        let hosts = localSubnetHosts()
        guard !hosts.isEmpty else { return [] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ProbeError.socket("socket() failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let message = searchMessage()
        var found: [String: DiscoveredConsole] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)

        func drain() {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, $0, &fromLen) }
            }
            guard count > 0 else { return }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            if let console = parseResponse(Data(buffer[0..<count]), from: String(cString: ip)) { found[console.id] = console }
        }

        for (index, host) in hosts.enumerated() {
            var dest = sockaddr_in()
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &dest.sin_addr) == 1 else { continue }
            _ = message.withUnsafeBytes { bytes in
                withUnsafePointer(to: &dest) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if index % 16 == 15 { usleep(4_000); drain() }      // pace the requests; pick up early replies
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen) }
            }
            guard count > 0 else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            if let console = parseResponse(Data(buffer[0..<count]), from: String(cString: ip)) { found[console.id] = console }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Finds consoles on the local network: a broadcast first, then each address directly if the
    /// broadcast brings nothing back.
    public static func searchNetwork(timeout: TimeInterval = 2) throws -> [DiscoveredConsole] {
        let viaBroadcast = (try? search(timeout: min(timeout, 1.5))) ?? []
        if !viaBroadcast.isEmpty { return viaBroadcast }
        return try searchSubnet(timeout: 2.5)
    }

    /// Blocking. Sends one search to `address` (broadcast by default, or a specific console IP)
    /// and collects replies until `timeout`. Call off the main thread.
    public static func search(address: String = "255.255.255.255", timeout: TimeInterval = 2) throws -> [DiscoveredConsole] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ProbeError.socket("socket() failed: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        // Ask for broadcast permission only for a broadcast. On an iPhone a socket marked for
        // broadcast is refused without Apple's multicast entitlement, which made a plain
        // one-address check fail and look like "no answer".
        if address == "255.255.255.255" {
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &dest.sin_addr) == 1 else { throw ProbeError.socket("Not an IPv4 address: \(address)") }

        let message = searchMessage()
        let sent = message.withUnsafeBytes { bytes in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == message.count else {
            throw ProbeError.socket("Could not send discovery request: \(String(cString: strerror(errno)))")
        }

        var found: [String: DiscoveredConsole] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLen)
                }
            }
            guard count > 0 else { continue }
            var ip = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ip, socklen_t(INET_ADDRSTRLEN))
            if let console = parseResponse(Data(buffer[0..<count]), from: String(cString: ip)) {
                found[console.id] = console
                if address != "255.255.255.255" { break }   // asked one console; it answered
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

/// Real PS5 source. Discovery works; pairing and streaming deliberately fail with an
/// honest "not implemented" error until the transport decision in docs/TECH_DECISION.md is made.
public final class PS5ConsoleSource: ConsoleSource {
    public let kind: ConsoleKind = .ps5
    public let isDemo = false
    public let supportsPairing = false
    public init() {}

    public func discover(address: String?, timeout: TimeInterval) async throws -> [DiscoveredConsole] {
        try await Task.detached {
            if let address, !address.isEmpty { return try PS5Discovery.search(address: address, timeout: timeout) }
            return try PS5Discovery.searchNetwork(timeout: timeout)
        }.value
    }

    public func register(_ request: PairingRequest) async throws -> (ConsoleDescriptor, PairingSecret) {
        throw SessionFailure.transportNotImplemented
    }

    public func openSession(console: ConsoleDescriptor, secret: PairingSecret, config: StreamConfig,
                            destination: DisplayDestination?) async throws -> ConsoleSession {
        throw SessionFailure.transportNotImplemented
    }
}
