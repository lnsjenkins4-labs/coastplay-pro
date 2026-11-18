import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
import RGPCore

/// The native iPhone/iPad screen as a display destination: hardware H.264 decode through
/// `AVSampleBufferDisplayLayer`, and PCM audio through `AVAudioEngine`. Uses only Apple frameworks.
/// Frames arrive on the transport's threads; a lock guards the small amount of shared state.
final class NativeDisplayDestination: DisplayDestination {
    let destinationID = "native-screen"
    let capabilities = DisplayCapabilities(codecs: [.h264], maxWidth: 1920, maxHeight: 1080, maxFps: 60)

    let layer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var muted = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var queuedAudioFrames = 0
    private var receivedAudioPackets = 0, scheduledAudioBuffers = 0, droppedAudioPackets = 0
    private var audioStartError: String?
    private var audioRestarts = 0
    private var sessionStart = Date()
    private var noSoundLogged = false
    private var lastSoundLine = Date()
    private var needsAudioRestart = false
    private var configObserver: NSObjectProtocol?
    private var windowPeak: Int16 = 0
    #if DEBUG
    private var debugTimer: Timer?
    #endif

    /// Creator Mode taps. Unset in ordinary play. They receive only the gameplay picture and
    /// game sound, never anything from the app's interface.
    var videoTap: ((CMSampleBuffer) -> Void)?
    var audioTap: ((Data, Int, Int) -> Void)?
    var resetTap: (() -> Void)?

    /// Frames handed to the decoder since `prepare`. Lets tests and diagnostics confirm real playback.
    private(set) var enqueuedVideoFrames = 0

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func prepare(format: VideoFormat) throws {
        lock.lock()
        sps = nil; pps = nil; formatDescription = nil; enqueuedVideoFrames = 0; queuedAudioFrames = 0
        lock.unlock()
        DispatchQueue.main.async { self.layer.flushAndRemoveImage() }
        resetTap?()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        lock.lock()
        receivedAudioPackets = 0; scheduledAudioBuffers = 0; droppedAudioPackets = 0; audioRestarts = 0
        sessionStart = Date(); noSoundLogged = false; lastSoundLine = Date()
        lock.unlock()
    }

    // MARK: Video

    func enqueue(video frame: EncodedVideoFrame) {
        if frame.presentationTimeUs % 1_000_000 < 20_000 { noteSoundHealth() }
        let nals = Self.splitAnnexB(frame.data)
        var slices: [Data] = []
        lock.lock()
        for nal in nals {
            guard let first = nal.first else { continue }
            switch first & 0x1F {
            case 7: if sps != nal { sps = nal; formatDescription = nil }
            case 8: if pps != nal { pps = nal; formatDescription = nil }
            case 1, 5: slices.append(nal)
            default: break   // SEI, access-unit delimiters: not needed by the decoder
            }
        }
        if formatDescription == nil, let sps, let pps { formatDescription = Self.makeFormat(sps: sps, pps: pps) }
        let format = formatDescription
        lock.unlock()
        guard let format, !slices.isEmpty else { return }

        // AVCC: each NAL prefixed by its 4-byte big-endian length.
        var avcc = Data(capacity: frame.data.count + 4 * slices.count)
        for nal in slices {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard let sample = Self.makeSample(avcc, format: format) else { return }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
        videoTap?(sample)
        lock.lock(); enqueuedVideoFrames += 1; lock.unlock()
    }

    private static func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let bytes = [UInt8](data)
        let n = bytes.count
        var i = 0, start = -1
        while i + 2 < n {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start, bytes[end - 1] == 0 { end -= 1 }   // 4-byte start code
                    if end > start { nals.append(Data(bytes[start..<end])) }
                }
                start = i + 3
                i += 3
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { nals.append(Data(bytes[start..<n])) }
        return nals
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return format
    }

    private static func makeSample(_ avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return nil }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // Low latency: show each frame as soon as it is decoded instead of scheduling by timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    // MARK: Audio

    func enqueue(audio frame: AudioFrame) {
        guard case .pcmS16(let channels, let sampleRate) = frame.encoding, channels > 0 else { return }  // Opus not handled here
        audioTap?(frame.data, channels, sampleRate)
        lock.lock()
        defer { lock.unlock() }
        receivedAudioPackets += 1
        // iOS can stop the sound engine underneath us (a call, Siri, headphones or a speaker
        // connecting). Notice and start it again instead of staying silent for the session.
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.needsAudioRestart = true; self.lock.unlock()
            }
        }
        if audioFormat != nil, needsAudioRestart || !engine.isRunning {
            needsAudioRestart = false
            audioFormat = nil; queuedAudioFrames = 0; audioRestarts += 1
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        if audioFormat == nil || audioFormat?.channelCount != AVAudioChannelCount(channels) || audioFormat?.sampleRate != Double(sampleRate) {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else { return }
            audioFormat = format
            engine.stop()
            if player.engine == nil { engine.attach(player) }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do { try engine.start() } catch { audioFormat = nil; audioStartError = "\(error)"; return }
            player.volume = muted ? 0 : 1
            player.play()
        }
        guard let format = audioFormat else { return }
        let frames = frame.data.count / (2 * channels)
        // Keep at most ~80 ms queued; drop audio rather than let it trail the picture.
        guard frames > 0, queuedAudioFrames < Int(format.sampleRate) * 8 / 100,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { droppedAudioPackets += 1; return }
        scheduledAudioBuffers += 1
        buffer.frameLength = AVAudioFrameCount(frames)
        frame.data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for c in 0..<channels {
                guard let dst = buffer.floatChannelData?[c] else { continue }
                for i in 0..<frames { dst[i] = Float(src[i * channels + c]) / 32768 }
            }
        }
        queuedAudioFrames += frames
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queuedAudioFrames -= frames; self.lock.unlock()
        }
    }

    /// Called about once a second from the picture path. Writes plain facts about sound to the
    /// connection log: once if no sound has arrived, and a summary every 10 s when recording is on.
    func noteSoundHealth() {
        lock.lock()
        let now = Date()
        var lines: [String] = []
        if !noSoundLogged, receivedAudioPackets == 0, now.timeIntervalSince(sessionStart) > 6 {
            noSoundLogged = true
            lines.append("No sound has arrived from the console in the first 6 seconds.")
        }
        if now.timeIntervalSince(lastSoundLine) >= 10 {
            lastSoundLine = now
            if UserDefaults.standard.bool(forKey: "recordPlayQuality") {
                let volume = Int((AVAudioSession.sharedInstance().outputVolume * 100).rounded())
                lines.append("Sound: \(receivedAudioPackets) packets arrived, \(droppedAudioPackets) dropped to stay in step, engine \(engine.isRunning ? "running" : "STOPPED"), restarted \(audioRestarts) times, \(muted ? "MUTED in the app" : "not muted"), phone volume \(volume)%\(audioStartError.map { ", start error: \($0)" } ?? "").")
            }
        }
        lock.unlock()
        for line in lines { ConnectionLog.shared.add(line) }
    }

    func setMuted(_ muted: Bool) {
        lock.lock(); self.muted = muted; lock.unlock()
        player.volume = muted ? 0 : 1
    }

    func teardown() {
        lock.lock()
        let hadAudio = audioFormat != nil
        audioFormat = nil; queuedAudioFrames = 0
        sps = nil; pps = nil; formatDescription = nil
        lock.unlock()
        // Stop audio only after releasing the lock: stopping the player runs the completion
        // handlers of queued buffers, and those take the same lock. Holding it here froze Disconnect.
        if hadAudio { player.stop(); engine.stop() }
        DispatchQueue.main.async { self.layer.flushAndRemoveImage() }
    }
}

/// Hosts the destination's video layer in SwiftUI.
struct VideoSurfaceView: UIViewRepresentable {
    let destination: NativeDisplayDestination

    final class Host: UIView {
        var videoLayer: CALayer? { didSet { oldValue?.removeFromSuperlayer(); if let videoLayer { layer.addSublayer(videoLayer) } } }
        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            videoLayer?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeUIView(context: Context) -> Host {
        let view = Host()
        view.backgroundColor = .black
        view.videoLayer = destination.layer
        return view
    }

    func updateUIView(_ view: Host, context: Context) {}
}
