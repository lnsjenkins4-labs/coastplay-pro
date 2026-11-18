#if DEBUG
import Foundation
import RGPCore

/// Developer-only check of the real encoded outputs, with no console involved. Started with
/// the launch argument `-creatorSelfTest <path to an H.264 Annex-B file>`. It plays that file
/// through the same decoder path a console uses, then drives Creator Mode on a fixed timeline
/// and writes what happened to Documents/creator-selftest.json. Not compiled into release builds.
enum CreatorSelfTest {
    static func runIfRequested(display: NativeDisplayDestination) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-creatorSelfTest"), index + 1 < arguments.count,
              let stream = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])) else { return }
        let feedAddress = index + 2 < arguments.count ? arguments[index + 2] : "127.0.0.1:9710"
        UserDefaults.standard.set(true, forKey: "creatorMode")
        let units = accessUnits(stream)
        let hub = CreatorHub.shared
        let start = Date()
        var paused = false
        var log: [String: Any] = ["accessUnits": units.count]
        func at(_ seconds: Double, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }

        // The "console": 30 pictures a second plus a steady tone as game sound.
        try? display.prepare(format: VideoFormat(codec: .h264, width: 1280, height: 720))
        display.setMuted(true)
        Thread.detachNewThread {
            var n = 0, phase = 0.0
            while Date().timeIntervalSince(start) < 30 {
                if !paused, !units.isEmpty {
                    display.enqueue(video: EncodedVideoFrame(data: units[n % units.count], isKeyframe: false, presentationTimeUs: Int64(n) * 33_333))
                    var pcm = Data(capacity: 1600 * 4)
                    for _ in 0..<1600 {
                        var sample = Int16(sin(phase) * 9000).littleEndian; phase += 2 * .pi * 440 / 48_000
                        withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0); pcm.append(contentsOf: $0) }
                    }
                    display.enqueue(audio: AudioFrame(data: pcm, encoding: .pcmS16(channels: 2, sampleRate: 48_000), presentationTimeUs: 0))
                    n += 1
                }
                Thread.sleep(forTimeInterval: 1.0 / 30)
            }
        }

        at(0.5) { hub.replayOn = true; hub.startFeed(to: feedAddress); hub.startRecording() }
        at(4) { hub.markHighlight() }
        at(6) { hub.scene = .beRightBack }
        at(9) { hub.scene = .gameplay }
        at(11) { paused = true }                       // the game connection "drops"
        at(13.2) { log["sceneWhileGameplayLost"] = hub.effectiveScene.rawValue }
        at(14) { paused = false }
        at(16) { log["sceneAfterGameplayReturned"] = hub.effectiveScene.rawValue; log["health"] = "\(hub.health)" }
        at(17) { hub.saveReplay(seconds: 10) { log["replay"] = $0?.path ?? "FAILED" } }
        at(19) { log["markers"] = hub.markers.map(\.seconds); hub.stopRecording() }
        at(21) {
            hub.stopFeed()
            guard let recording = hub.clips.first(where: { $0.lastPathComponent.contains("Recording") }) else { log["recording"] = "MISSING"; finish(log); return }
            log["recording"] = recording.path
            guard let marker = hub.markers(for: recording).first else { log["highlight"] = "NO MARKER SAVED"; finish(log); return }
            hub.exportHighlight(from: recording, marker: marker, length: 3) { log["highlight"] = $0?.path ?? "FAILED"; finish(log) }
        }
    }

    private static func finish(_ log: [String: Any]) {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("creator-selftest.json")
        try? JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    /// Splits an Annex-B stream into pictures at access-unit delimiters.
    private static func accessUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 4 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 0, bytes[i + 3] == 1, bytes[i + 4] & 0x1F == 9 { starts.append(i); i += 5 } else { i += 1 }
        }
        return starts.enumerated().map { index, start in Data(bytes[start..<(index + 1 < starts.count ? starts[index + 1] : bytes.count)]) }
    }
}
#endif
