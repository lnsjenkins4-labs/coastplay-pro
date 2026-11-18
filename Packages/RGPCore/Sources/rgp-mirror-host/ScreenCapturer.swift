import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import AVFoundation

/// Captures the main display and system sound, and encodes video as low-latency H.264.
/// Emits Annex-B access units and interleaved 16-bit PCM (48 kHz stereo).
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// One encoded picture, and whether it is a keyframe (a picture that stands on its own).
    var onVideo: ((Data, Bool) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onStopped: ((String) -> Void)?

    private(set) var width = 0
    private(set) var height = 0
    let fps = 60

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private let videoQueue = DispatchQueue(label: "rgp.host.video")
    private let audioQueue = DispatchQueue(label: "rgp.host.audio")
    private let lock = NSLock()
    private var forceKeyframe = true

    /// The display being shared. The pointer must be placed on this same display.
    private(set) var displayID = CGMainDisplayID()

    func requestKeyframe() { lock.lock(); forceKeyframe = true; lock.unlock() }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "RGPHost", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        displayID = display.displayID
        // Scale to at most 1280 wide, keeping the display's shape; even dimensions for the encoder.
        let scale = min(1.0, 1280.0 / Double(display.width))
        width = Int(Double(display.width) * scale) & ~1
        height = Int(Double(display.height) * scale) & ~1

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 3
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        try makeEncoder()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
    }

    static let minBitrate = 1_000_000, maxBitrate = 8_000_000
    /// Picture data rate in bits per second. Adjusted while running to suit the network.
    private(set) var bitrate = 5_000_000

    func setBitrate(_ value: Int) {
        let clamped = min(Self.maxBitrate, max(Self.minBitrate, value))
        guard clamped != bitrate else { return }
        bitrate = clamped
        guard let encoder else { return }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: clamped as CFNumber)
    }

    private func makeEncoder() throws {
        var session: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw NSError(domain: "RGPHost", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not create the video encoder (\(status))"])
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 4) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        // No hard data-rate cap here: the encoder obeys one by throwing pictures away, which cut a
        // game to about 13 pictures a second (seen 2026-11-18). The flow control in the host app
        // is what protects a slow network.
        VTCompressionSessionPrepareToEncodeFrames(session)
        encoder = session
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen: encode(sampleBuffer)
        case .audio: forwardAudio(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(error.localizedDescription)
    }

    // Picture facts for the log: what macOS delivered, how many of those were new pictures, and
    // how many came out of the encoder.
    private var picDelivered = 0, picNew = 0, picEncoded = 0

    func takePictureStats() -> (delivered: Int, new: Int, encoded: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        let result = (picDelivered, picNew, picEncoded)
        picDelivered = 0; picNew = 0; picEncoded = 0
        return result
    }

    private func encode(_ sampleBuffer: CMSampleBuffer) {
        statsLock.lock(); picDelivered += 1; statsLock.unlock()
        // Only complete frames carry new pixels; idle frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixels = sampleBuffer.imageBuffer, let encoder, onVideo != nil else { return }
        statsLock.lock(); picNew += 1; statsLock.unlock()
        lock.lock(); let key = forceKeyframe; forceKeyframe = false; lock.unlock()
        let properties: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: pixels, presentationTimeStamp: sampleBuffer.presentationTimeStamp,
                                        duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self, let unit = Self.annexB(from: encoded) else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(encoded, createIfNecessary: false) as? [[CFString: Any]]
            let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            self.statsLock.lock(); self.picEncoded += 1; self.statsLock.unlock()
            self.onVideo?(unit, isKeyframe)
        }
    }

    /// Converts the encoder's length-prefixed output to Annex-B, adding SPS/PPS before keyframes.
    private static func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else { return nil }
        let startCode: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if isKeyframe {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: startCode)
                    out.append(pointer, count: size)
                }
            }
        }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr, let dataPointer else { return nil }
        var offset = 0
        while offset + 4 <= totalLength {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, dataPointer + offset, 4)
            let length = Int(UInt32(bigEndian: nalLength))
            offset += 4
            guard length > 0, offset + length <= totalLength else { break }
            out.append(contentsOf: startCode)
            dataPointer.withMemoryRebound(to: UInt8.self, capacity: totalLength) { out.append($0 + offset, count: length) }
            offset += length
        }
        return out.isEmpty ? nil : out
    }

    // Sound facts for the status log: how many sound buffers macOS delivered, how many we could
    // convert and pass on, and the loudest level seen (0 = silence).
    private let statsLock = NSLock()
    private var soundDelivered = 0, soundForwarded = 0, soundPeak: Float32 = 0
    private var soundFormatNote = ""

    func takeSoundStats() -> (delivered: Int, forwarded: Int, peakPercent: Int, format: String) {
        statsLock.lock(); defer { statsLock.unlock() }
        let result = (soundDelivered, soundForwarded, Int((soundPeak * 100).rounded()), soundFormatNote)
        soundDelivered = 0; soundForwarded = 0; soundPeak = 0
        return result
    }

    private func forwardAudio(_ sampleBuffer: CMSampleBuffer) {
        statsLock.lock(); soundDelivered += 1
        if soundFormatNote.isEmpty, let d = sampleBuffer.formatDescription?.audioStreamBasicDescription {
            soundFormatNote = "\(Int(d.mSampleRate)) Hz, \(d.mChannelsPerFrame) ch, \(d.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "integer"), \(d.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "separate channels" : "interleaved")"
        }
        statsLock.unlock()
        guard let onAudio else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                  description.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
            let frames = sampleBuffer.numSamples
            guard frames > 0 else { return }
            var pcm = [Int16](repeating: 0, count: frames * 2)
            let interleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            if interleaved, let data = list.first?.mData {
                let channels = Int(description.mChannelsPerFrame)
                let source = data.bindMemory(to: Float32.self, capacity: frames * channels)
                for i in 0..<frames {
                    pcm[i * 2] = Self.sample(source[i * channels])
                    pcm[i * 2 + 1] = Self.sample(source[i * channels + min(1, channels - 1)])
                }
            } else {
                let left = list.first?.mData?.bindMemory(to: Float32.self, capacity: frames)
                let right = (list.count > 1 ? list[1].mData : list.first?.mData)?.bindMemory(to: Float32.self, capacity: frames)
                guard let left, let right else { return }
                for i in 0..<frames {
                    pcm[i * 2] = Self.sample(left[i])
                    pcm[i * 2 + 1] = Self.sample(right[i])
                }
            }
            var peak: Int16 = 0
            for v in pcm where abs(Int32(v)) > Int32(peak) { peak = Int16(min(32767, abs(Int32(v)))) }
            statsLock.lock(); soundForwarded += 1; soundPeak = max(soundPeak, Float32(peak) / 32767); statsLock.unlock()
            onAudio(pcm.withUnsafeBufferPointer { Data(buffer: $0) })
        }
    }

    private static func sample(_ value: Float32) -> Int16 { Int16(max(-1, min(1, value)) * 32767) }
}
