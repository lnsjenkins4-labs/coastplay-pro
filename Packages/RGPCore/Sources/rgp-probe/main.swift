import Foundation
import RGPPS5
import RGPCore

// Desktop diagnostic harness. Usage:
//   swift run rgp-probe            broadcast on the local network
//   swift run rgp-probe 192.168.1.50   ask one specific address
// Sends a single PS5 discovery request and prints any consoles that answer.
// It does not pair, wake, or stream.

let target = CommandLine.arguments.dropFirst().first ?? "255.255.255.255"
print("Looking for PS5 consoles via \(target):\(PS5Discovery.port) (3 s)…")
do {
    let consoles = target == "255.255.255.255" ? try PS5Discovery.searchNetwork(timeout: 3) : try PS5Discovery.search(address: target, timeout: 3)
    if consoles.isEmpty {
        print("No PS5 answered. Check that the console is on (or in rest mode with network features enabled)")
        print("and that this computer is on the same network. Some routers block broadcast; try the console's IP.")
        exit(2)
    }
    for c in consoles {
        if let ms = NetworkProbe.typicalPingMs(host: c.address) { print("PING   \(c.address)  network round-trip \(Int(ms.rounded())) ms") }
        print("FOUND  name=\(c.name)  address=\(c.address)  status=\(c.status.rawValue)  system-version=\(c.systemVersion ?? "?")")
    }
} catch {
    print("Probe error: \(error)")
    exit(1)
}
