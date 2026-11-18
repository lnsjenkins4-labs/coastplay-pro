import AVFoundation
import Combine
import CoreMedia
import Network
import UIKit
import RGPCore

/// Creator Mode's switchboard. Gameplay pictures and game sound come in from the display
/// destination's taps; from here they go to the public outputs (external display, network
/// feed) and the local tools (recording, replay buffer).
///
/// Privacy rule: the only things that can reach a public output are decoded gameplay pictures,
/// game sound, and the fixed scene cards. No view from the app's interface is ever captured.
final class CreatorHub: ObservableObject {
    static let shared = CreatorHub()

    struct Health: Equatable {
        var incomingFps = 0.0          // gameplay pictures decoded for creator outputs
        var decodeFailures = 0
        var feedKbps = 0.0             // what we are sending to the network feed
        var feedFps = 0.0
        var freeGB: Double?
        var thermal = "Normal"
        var batteryPercent: Int?
    }

    // Shown in the interface (main thread).
    @Published var scene: PublicScene = .gameplay { didSet { let s = scene; q.async { self.chosen = s; self.tick() } } }
    @Published private(set) var effectiveScene: PublicScene = .reconnecting
    @Published private(set) var externalConnected = false
    @Published private(set) var feedState: CreatorLinkState = .off
    @Published private(set) var recording = false
    @Published private(set) var recordingSeconds = 0.0
    @Published private(set) var markers: [HighlightMarker] = []
    @Published private(set) var clips: [URL] = []
    @Published private(set) var replaySeconds = 0.0
    @Published private(set) var health = Health()
    @Published var notice: String?
    /// True while a play session is running or reconnecting. Set by the app.
    @Published var sessionActive = false
    /// True while a TV or monitor is attached. Read from the picture path to decide whether the
    /// second decoder is needed.
    private(set) static var externalAttached = false
    @Published var replayOn = UserDefaults.standard.bool(forKey: "creatorReplay") {
        didSet { UserDefaults.standard.set(replayOn, forKey: "creatorReplay"); let on = replayOn; q.async { self.replayWanted = on; if !on { self.ring.removeAll(); self.audioRing.removeAll() } } }
    }
    @Published var muteGameOnPrivacyScenes = UserDefaults.standard.object(forKey: "creatorMuteOnBRB") as? Bool ?? true {
        didSet { UserDefaults.standard.set(muteGameOnPrivacyScenes, forKey: "creatorMuteOnBRB"); let on = muteGameOnPrivacyScenes; q.async { self.muteOnPrivacy = on } }
    }

    /// The clean gameplay layer for an external display. Fed only with decoded game pictures.
    let publicLayer = AVSampleBufferDisplayLayer()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "creatorMode") }
    static let clipsFolder: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Clips")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    // Everything below is touched only on `q`.
    private let q = DispatchQueue(label: "coastplay.creator")
    private let tap = GameFrameTap()
    private let cleanEncoder = FeedEncoder(bitrate: 8_000_000)
    private let publicEncoder = FeedEncoder(bitrate: 4_500_000)
    private var chosen = PublicScene.gameplay
    private var effective = PublicScene.reconnecting
    private var lastGameFrame = Date.distantPast
    private var gameSize = (width: 1280, height: 720)
    private var external = false
    private var replayWanted = UserDefaults.standard.bool(forKey: "creatorReplay")
    private var muteOnPrivacy = UserDefaults.standard.object(forKey: "creatorMuteOnBRB") as? Bool ?? true
    private var ring: [(sample: CMSampleBuffer, key: Bool, time: CMTime)] = []
    private var audioRing: [(pcm: Data, time: CMTime)] = []
    private var writer: ClipWriter?
    private var pendingMarkers: [HighlightMarker] = []
    private var feed: NWConnection?
    private var mux = MPEGTSMuxer(hasAudio: true)
    private var aac = AACEncoder()
    private var feedStart = CMTime.zero
    private var feedAudioAnchor: CMTime?
    private var feedAudioFrames: Int64 = 0
    private var feedBytes = 0, feedFrames = 0, lastDecoded = 0
    private var cards: [String: CVPixelBuffer] = [:]
    private var timer: DispatchSourceTimer?
    private var ticks = 0

    private init() {
        publicLayer.videoGravity = .resizeAspect
        publicLayer.backgroundColor = UIColor.black.cgColor
        tap.onFrame = { [weak self] pixels in self?.gameFrame(pixels) }
        cleanEncoder.onEncoded = { [weak self] sample, key in self?.q.async { self?.cleanEncoded(sample, key) } }
        publicEncoder.onEncoded = { [weak self] sample, key in self?.q.async { self?.publicEncoded(sample, key) } }
        refreshClips()
    }

    private var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Connects the hub to the screen's decoder. Does nothing unless Creator Mode is on, so
    /// ordinary play keeps exactly the path it had before.
    func attach(to display: NativeDisplayDestination) {
        display.videoTap = { [weak self] sample in
            guard Self.isEnabled || Self.externalAttached, let self else { return }
            self.q.async { self.tap.decode(sample) }
        }
        display.audioTap = { [weak self] pcm, channels, rate in
            guard Self.isEnabled, channels == 2, rate == 48_000, let self else { return }
            self.q.async { self.gameSound(pcm) }
        }
        display.resetTap = { [weak self] in self?.q.async { self?.tap.reset() } }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let timer = DispatchSource.makeTimerSource(queue: q)
        timer.schedule(deadline: .now() + 0.1, repeating: 1.0 / 15)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // MARK: Incoming gameplay

    private func gameFrame(_ pixels: CVPixelBuffer) {
        lastGameFrame = Date()
        gameSize = (CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels))
        let time = now
        if external, effective == .gameplay { show(pixels, at: time) }
        if replayWanted || writer != nil { cleanEncoder.encode(pixels, at: time) }
        if feed != nil, effective == .gameplay { publicEncoder.encode(pixels, at: time) }
    }

    private func gameSound(_ pcm: Data) {
        let time = now
        if replayWanted { audioRing.append((pcm, time)) }
        writer?.append(pcm: pcm, at: time)
        guard feed != nil else { return }
        let silent = muteOnPrivacy && effective.hidesGameplay
        for frame in aac.encode(silent ? Data(count: pcm.count) : pcm) {
            if let anchor = feedAudioAnchor, (time - (anchor + CMTime(value: feedAudioFrames * 1024, timescale: 48_000))).seconds > 0.25 {
                feedAudioAnchor = nil; feedAudioFrames = 0      // sound resumed after a gap: line it up with the picture again
            }
            if feedAudioAnchor == nil { feedAudioAnchor = time }
            let stamp = (feedAudioAnchor! - feedStart) + CMTime(value: feedAudioFrames * 1024, timescale: 48_000)
            feedAudioFrames += 1
            send(mux.audio(adts: MPEGTSMuxer.adtsHeader(frameLength: frame.count, sampleRate: 48_000, channels: 2) + frame,
                           pts90k: UInt64(max(0, stamp.seconds) * 90_000)))
        }
    }

    private func show(_ pixels: CVPixelBuffer, at time: CMTime) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if publicLayer.status == .failed { publicLayer.flush() }
        publicLayer.enqueue(sample)
    }

    /// Runs 15 times a second: decides what the audience gets, keeps the feed alive with a
    /// card when there is no gameplay to send, and publishes status once a second.
    private func tick() {
        let arriving = Date().timeIntervalSince(lastGameFrame) < 1.5
        let next = PublicScene.effective(chosen: chosen, gameplayArriving: arriving)
        if next != effective {
            effective = next
            if next != .gameplay { DispatchQueue.main.async { self.publicLayer.flushAndRemoveImage() } }
            publicEncoder.requestKeyframe()
            DispatchQueue.main.async { self.effectiveScene = next }
        }
        if feed != nil, effective != .gameplay, let card = card(effective) { publicEncoder.encode(card, at: now) }
        ticks += 1
        guard ticks % 15 == 0 else { return }
        var h = Health()
        h.incomingFps = Double(tap.decoded - lastDecoded); lastDecoded = tap.decoded
        h.decodeFailures = tap.failed
        h.feedKbps = Double(feedBytes) * 8 / 1000; h.feedFps = Double(feedFrames); feedBytes = 0; feedFrames = 0
        if let free = try? Self.clipsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
            h.freeGB = Double(free) / 1_000_000_000
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: h.thermal = "Normal"
        case .fair: h.thermal = "Warm"
        case .serious: h.thermal = "Hot"
        case .critical: h.thermal = "Too hot"
        @unknown default: h.thermal = "Unknown"
        }
        let level = UIDevice.current.batteryLevel
        h.batteryPercent = level >= 0 ? Int((level * 100).rounded()) : nil
        let seconds = writer?.seconds ?? 0
        let span = (ring.first.map { (now - $0.time).seconds }) ?? 0
        if writer != nil, let free = h.freeGB, free < 0.2 { stopRecordingLocked(reason: "Recording stopped: the phone is almost out of storage.") }
        DispatchQueue.main.async {
            self.health = h; self.recordingSeconds = seconds; self.replaySeconds = min(60, span)
        }
    }

    private func card(_ scene: PublicScene) -> CVPixelBuffer? {
        let key = "\(scene.rawValue)-\(gameSize.width)x\(gameSize.height)"
        if let cached = cards[key] { return cached }
        let made = SceneCard.pixelBuffer(scene, width: gameSize.width, height: gameSize.height)
        cards[key] = made
        return made
    }

    // MARK: External display

    func setExternalDisplay(connected: Bool) {
        Self.externalAttached = connected
        q.async { self.external = connected }
        DispatchQueue.main.async {
            self.externalConnected = connected
            if !connected { self.publicLayer.flushAndRemoveImage() }
            ConnectionLog.shared.add(connected ? "External display connected: showing the clean output." : "External display removed.")
        }
    }

    // MARK: Recording, replay, highlights

    private func cleanEncoded(_ sample: CMSampleBuffer, _ key: Bool) {
        writer?.append(video: sample, isKeyframe: key)
        guard replayWanted else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        ring.append((sample, key, time))
        // Keep about a minute, always starting on a keyframe so a saved replay opens cleanly.
        while let first = ring.first, (time - first.time).seconds > 62,
              let next = ring.dropFirst().firstIndex(where: { $0.key }), (time - ring[next].time).seconds >= 60 {
            ring.removeFirst(next)
        }
        while let first = audioRing.first, (time - first.time).seconds > 62 { audioRing.removeFirst() }
    }

    func startRecording() {
        q.async {
            guard self.writer == nil else { return }
            if let free = try? Self.clipsFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free < 500_000_000 {
                DispatchQueue.main.async { self.notice = "Not enough free storage to record. Free up at least 0.5 GB." }
                return
            }
            guard let writer = ClipWriter(url: Self.newURL("Recording"), realTime: true) else {
                DispatchQueue.main.async { self.notice = "The recording file could not be created." }
                return
            }
            self.writer = writer; self.pendingMarkers = []
            self.cleanEncoder.requestKeyframe()
            DispatchQueue.main.async { self.recording = true; self.markers = []; self.recordingSeconds = 0 }
        }
    }

    func stopRecording() { q.async { self.stopRecordingLocked(reason: nil) } }

    private func stopRecordingLocked(reason: String?) {
        guard let writer else { return }
        self.writer = nil
        let saved = pendingMarkers
        writer.finish { url in
            if let url, !saved.isEmpty, let data = try? JSONEncoder().encode(saved) {
                try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
            DispatchQueue.main.async {
                self.recording = false
                self.notice = reason ?? (url == nil ? "The recording had no picture, so nothing was saved." : nil)
                self.refreshClips()
            }
        }
    }

    /// Flags this moment in the recording that is running.
    func markHighlight() {
        q.async {
            guard let writer = self.writer else { return }
            let marker = HighlightMarker(seconds: writer.seconds)
            self.pendingMarkers.append(marker)
            let all = self.pendingMarkers
            DispatchQueue.main.async { self.markers = all }
        }
    }

    /// Saves the last `seconds` of clean gameplay from CoastPlay's own replay buffer.
    func saveReplay(seconds: Double, done: ((URL?) -> Void)? = nil) {
        q.async {
            let end = self.now
            guard let start = self.ring.firstIndex(where: { $0.key && (end - $0.time).seconds <= seconds }) else {
                DispatchQueue.main.async { self.notice = self.replayOn ? "Nothing to save yet: the replay buffer is still filling." : "Turn on Instant replay first."; done?(nil) }
                return
            }
            let pictures = Array(self.ring[start...])
            let sound = self.audioRing.filter { $0.time >= pictures[0].time }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let writer = ClipWriter(url: Self.newURL("Replay"), realTime: false) else { done?(nil); return }
                var next = 0
                for picture in pictures {
                    while next < sound.count, sound[next].time <= picture.time { writer.append(pcm: sound[next].pcm, at: sound[next].time); next += 1 }
                    writer.append(video: picture.sample, isKeyframe: picture.key)
                }
                writer.finish { url in
                    DispatchQueue.main.async {
                        if url == nil { self.notice = "The replay could not be saved." }
                        self.refreshClips(); done?(url)
                    }
                }
            }
        }
    }

    /// Cuts the stretch before a highlight marker out of a finished recording. No re-encoding.
    func exportHighlight(from recording: URL, marker: HighlightMarker, length: Double, done: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: recording)
        Task {
            guard let duration = try? await asset.load(.duration),
                  let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { done(nil); return }
            let range = marker.clipRange(length: length, recordingDuration: duration.seconds)
            let url = Self.newURL("Highlight")
            export.outputURL = url; export.outputFileType = .mp4
            export.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                                           end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
            await export.export()
            let ok = export.status == .completed
            await MainActor.run {
                if !ok { self.notice = "That highlight could not be exported." }
                self.refreshClips(); done(ok ? url : nil)
            }
        }
    }

    func markers(for recording: URL) -> [HighlightMarker] {
        guard let data = try? Data(contentsOf: recording.deletingPathExtension().appendingPathExtension("json")) else { return [] }
        return (try? JSONDecoder().decode([HighlightMarker].self, from: data)) ?? []
    }

    func delete(_ clip: URL) {
        try? FileManager.default.removeItem(at: clip)
        try? FileManager.default.removeItem(at: clip.deletingPathExtension().appendingPathExtension("json"))
        refreshClips()
    }

    func refreshClips() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.clipsFolder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let sorted = files.filter { $0.pathExtension == "mp4" }.sorted {
            ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        DispatchQueue.main.async { self.clips = sorted }
    }

    private static func newURL(_ kind: String) -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return clipsFolder.appendingPathComponent("CoastPlay \(kind) \(formatter.string(from: Date())).mp4")
    }

    // MARK: Network feed (to OBS on the same network)

    /// Starts sending the audience feed to a computer, e.g. "192.168.1.20:9710". The phone sends
    /// straight to that address: no CoastPlay server is involved.
    func startFeed(to address: String) {
        let parts = address.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), let nwPort = NWEndpoint.Port(rawValue: port), !parts[0].isEmpty else {
            notice = "Type the computer's address like 192.168.1.20:9710."
            return
        }
        let host = String(parts[0])
        feedState = .waiting("Opening…")
        q.async {
            self.feed?.cancel()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
            connection.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready: self.feedState = .live
                    case .waiting(let error): self.feedState = .failed("Can't send: \(error.localizedDescription)")
                    case .failed(let error): self.feedState = .failed("Stopped: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
            self.mux = MPEGTSMuxer(hasAudio: true); self.aac = AACEncoder()
            self.feedStart = self.now; self.feedAudioAnchor = nil; self.feedAudioFrames = 0
            self.feed = connection
            self.publicEncoder.requestKeyframe()
            connection.start(queue: self.q)
            ConnectionLog.shared.add("Network feed started.")
        }
    }

    func stopFeed() {
        q.async { self.feed?.cancel(); self.feed = nil; self.publicEncoder.close() }
        feedState = .off
        ConnectionLog.shared.add("Network feed stopped.")
    }

    func setFeedBitrate(kbps: Int) { q.async { self.publicEncoder.bitrate = kbps * 1000 } }

    private func publicEncoded(_ sample: CMSampleBuffer, _ key: Bool) {
        guard feed != nil, let data = FeedEncoder.annexB(sample, isKeyframe: key) else { return }
        let stamp = CMSampleBufferGetPresentationTimeStamp(sample) - feedStart
        var out = key ? mux.tables() : Data()
        out += mux.video(annexB: data, pts90k: UInt64(max(0, stamp.seconds) * 90_000), isKeyframe: key)
        feedFrames += 1
        send(out)
    }

    private func send(_ data: Data) {
        guard let feed else { return }
        feedBytes += data.count
        var offset = 0
        while offset < data.count {          // seven transport packets per datagram
            let end = min(offset + 1316, data.count)
            feed.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { _ in })
            offset = end
        }
    }
}
