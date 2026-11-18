import Foundation

/// A short, plain-language record of recent connection attempts, kept on the device so a person
/// (or support) can see which step failed. It never contains passwords, tokens, pairing keys,
/// account identifiers, picture or sound. Only the last 200 lines are kept.
public final class ConnectionLog: @unchecked Sendable {
    public static let shared = ConnectionLog()
    private let lock = NSLock()
    private var lines: [String] = []
    private let url: URL?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm:ss"
        return f
    }()

    private init() {
        url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("connection-log.txt")
        if let url, let saved = try? String(contentsOf: url, encoding: .utf8) {
            lines = saved.split(separator: "\n").map(String.init).suffix(200)
        }
    }

    public func add(_ text: String) {
        lock.lock()
        lines.append("\(formatter.string(from: Date()))  \(text)")
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        let snapshot = lines.joined(separator: "\n")
        lock.unlock()
        if let url { try? snapshot.write(to: url, atomically: true, encoding: .utf8) }
    }

    public var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.isEmpty ? "No connection attempts recorded yet." : lines.joined(separator: "\n")
    }

    public func clear() {
        lock.lock(); lines = []; lock.unlock()
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}
