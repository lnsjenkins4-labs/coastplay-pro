import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox
import RGPCore

// Building blocks for Creator Mode. Each one does a single job and knows nothing about the
// app's screens, so nothing from the private interface can reach a public output through them.

/// Decodes a second copy of the incoming gameplay into plain pictures. The player's own view
/// keeps its separate low-latency path; this copy feeds recordings and the audience feed.
final class GameFrameTap {
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var session: VTDecompressionSession?
    private(set) var decoded = 0, failed = 0

    func decode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || !VTDecompressionSessionCanAcceptFormatDescription(session!, formatDescription: format) { open(format) }
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status == noErr, let image { self.decoded += 1; self.onFrame?(image) } else { self.failed += 1 }
        }
        if status != noErr { failed += 1 }
    }

    private func open(_ format: CMVideoFormatDescription) {
        reset()
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                     imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
    }
}

/// Encodes pictures to H.264 with a keyframe every second, so a recording, a replay or a
/// receiver can start at any moment without waiting on the console.
final class FeedEncoder {
    var onEncoded: ((CMSampleBuffer, Bool) -> Void)?
    private var session: VTCompressionSession?
    private var width = 0, height = 0
    private var wantKeyframe = true
    var bitrate: Int { didSet { if let session { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber) } } }
    private(set) var encoded = 0

    init(bitrate: Int) { self.bitrate = bitrate }

    var size: CGSize { CGSize(width: width, height: height) }
    func requestKeyframe() { wantKeyframe = true }

    func encode(_ pixels: CVPixelBuffer, at time: CMTime) {
        let w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        if session == nil || w != width || h != height { open(width: w, height: h) }
        guard let session else { return }
        let properties: CFDictionary? = wantKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        wantKeyframe = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            self.encoded += 1
            self.onEncoded?(sample, isKeyframe)
        }
    }

    private func open(width: Int, height: Int) {
        close()
        self.width = width; self.height = height
        VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                   encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        wantKeyframe = true
    }

    func close() {
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(session) }
        session = nil
    }

    /// The picture as start-code (Annex-B) bytes, with the stream's settings in front of keyframes.
    static func annexB(_ sample: CMSampleBuffer, isKeyframe: Bool) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var out = Data()
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?, size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: [0, 0, 0, 1]); out.append(pointer, count: size)
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr else { return nil }
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= bytes.count else { break }
            out.append(contentsOf: [0, 0, 0, 1]); out.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        }
        return out
    }
}

/// Turns the game's raw sound into AAC frames for the network feed.
final class AACEncoder {
    private let input = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private var pending = Data()

    init() {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        output = AVAudioFormat(streamDescription: &description)!
        converter = AVAudioConverter(from: input, to: output)
        converter?.bitRate = 128_000
    }

    /// Feed 48 kHz stereo 16-bit sound; get back zero or more complete AAC frames.
    func encode(_ pcm: Data) -> [Data] {
        guard let converter else { return [] }
        pending.append(pcm)
        var frames: [Data] = []
        let chunk = 1024 * 4
        while pending.count >= chunk {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 1024) else { break }
            buffer.frameLength = 1024
            pending.prefix(chunk).withUnsafeBytes { raw in
                if let destination = buffer.int16ChannelData?[0], let source = raw.baseAddress { memcpy(destination, source, chunk) }
            }
            pending.removeFirst(chunk)
            let packet = AVAudioCompressedBuffer(format: output, packetCapacity: 1, maximumPacketSize: converter.maximumOutputPacketSize)
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: packet, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            if (status == .haveData || status == .inputRanDry), packet.byteLength > 0 {
                frames.append(Data(bytes: packet.data, count: Int(packet.byteLength)))
            }
        }
        return frames
    }
}

/// Writes an .mp4 from already-encoded pictures plus raw game sound.
final class ClipWriter {
    let url: URL
    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput?
    private var audio: AVAssetWriterInput?
    /// True when pictures arrive live and must never wait; false when writing from memory,
    /// where a short wait for the file writer is fine.
    private let realTime: Bool
    private(set) var startTime: CMTime?
    private(set) var lastTime = CMTime.zero
    private(set) var videoFrames = 0, droppedFrames = 0
    private var audioSamples: Int64 = 0
    private var audioStart: CMTime?
    private static let pcm: CMAudioFormatDescription? = {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        return format
    }()

    init?(url: URL, realTime: Bool) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        self.url = url; self.writer = writer; self.realTime = realTime
    }

    var seconds: Double { startTime.map { max(0, (lastTime - $0).seconds) } ?? 0 }

    /// The first picture must be a keyframe; earlier pictures are ignored.
    func append(video sample: CMSampleBuffer, isKeyframe: Bool) {
        if video == nil {
            guard isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) else { return }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            sound.expectsMediaDataInRealTime = true
            guard writer.canAdd(input), writer.canAdd(sound) else { return }
            writer.add(input); writer.add(sound)
            guard writer.startWriting() else { return }
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            writer.startSession(atSourceTime: start)
            video = input; audio = sound; startTime = start
        }
        guard let video, writer.status == .writing else { return }
        if !realTime { wait(for: video) }
        guard video.isReadyForMoreMediaData else { droppedFrames += 1; return }
        if video.append(sample) { videoFrames += 1; lastTime = CMSampleBufferGetPresentationTimeStamp(sample) }
    }

    /// Raw 48 kHz stereo 16-bit game sound that arrived at `time`.
    func append(pcm: Data, at time: CMTime) {
        guard let audio, let startTime, writer.status == .writing, let format = Self.pcm, time >= startTime else { return }
        let frames = pcm.count / 4
        guard frames > 0 else { return }
        // After a gap in the game's sound (a network hiccup, a reconnect) the count would fall
        // behind the picture for good, so start counting again from the arrival time.
        if let start = audioStart, (time - (start + CMTime(value: audioSamples, timescale: 48_000))).seconds > 0.25 { audioStart = nil; audioSamples = 0 }
        if audioStart == nil { audioStart = time }
        // Sound is timed by counting samples from its first packet, so it plays back evenly
        // even though packets arrive in bursts.
        let stamp = audioStart! + CMTime(value: audioSamples, timescale: 48_000)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: pcm.count, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: pcm.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return }
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count) }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                                                    presentationTimeStamp: stamp, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if !realTime { wait(for: audio) }
        if audio.isReadyForMoreMediaData, audio.append(sample) { audioSamples += Int64(frames) }
    }

    /// Waits briefly for the file writer to catch up; gives up rather than hang.
    private func wait(for input: AVAssetWriterInput) {
        var waited = 0
        while !input.isReadyForMoreMediaData, writer.status == .writing, waited < 1000 { usleep(2000); waited += 1 }
    }

    /// Finishes the file. Returns nil if nothing usable was written.
    func finish(_ done: @escaping (URL?) -> Void) {
        guard video != nil, writer.status == .writing else { writer.cancelWriting(); done(nil); return }
        video?.markAsFinished(); audio?.markAsFinished()
        writer.finishWriting { [writer, url, videoFrames] in done(writer.status == .completed && videoFrames > 0 ? url : nil) }
    }
}

/// Full-screen cards for the audience feed (Be right back, Reconnecting…). Drawn from fixed
/// text and the app's colours only: nothing from the app's live screens is ever read.
enum SceneCard {
    static func image(_ scene: PublicScene, size: CGSize, title override: String? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1).setFill(); context.fill(bounds)
            let accent = UIColor(Theme.accent)
            accent.withAlphaComponent(0.9).setFill()
            context.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: max(2, size.height * 0.006)))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            let title = NSAttributedString(string: override ?? scene.title, attributes: [
                .font: UIFont.systemFont(ofSize: size.height * (override == nil ? 0.11 : 0.08), weight: .bold), .foregroundColor: UIColor.white, .paragraphStyle: style])
            title.draw(in: CGRect(x: 0, y: size.height * 0.40, width: size.width, height: size.height * 0.16))
            let brand = NSAttributedString(string: "CoastPlay PRO", attributes: [
                .font: UIFont.systemFont(ofSize: size.height * 0.04, weight: .semibold), .foregroundColor: accent, .paragraphStyle: style])
            brand.draw(in: CGRect(x: 0, y: size.height * 0.67, width: size.width, height: size.height * 0.07))
        }
    }

    static func pixelBuffer(_ scene: PublicScene, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess, let buffer,
              let image = image(scene, size: CGSize(width: width, height: height)).cgImage else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
