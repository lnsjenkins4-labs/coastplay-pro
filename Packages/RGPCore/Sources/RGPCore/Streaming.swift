import Foundation

// MARK: - B. Streaming and playback contracts

/// Measurements a transport can actually observe. Every field is optional: show "—" rather
/// than invent a number. `roundTripMs` is NETWORK round-trip time to the console only. It is
/// not input-to-display latency (which also includes capture, encode, decode and display time)
/// and must never be labelled as such.
public struct StreamStats: Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var framesPerSecond: Double?
    public var bitrateKbps: Double?
    public var packetLossPercent: Double?
    public var roundTripMs: Double?
    /// True when the numbers come from the mock source rather than a measured stream.
    public var isSimulated: Bool
    /// True when the transport has measured, over the last several seconds, pictures being lost
    /// or arriving in long gaps, or the network delay swinging high. A measured fact about the
    /// network path, not a guess; false when not measured.
    public var isUnstable = false

    public init(width: Int? = nil, height: Int? = nil, framesPerSecond: Double? = nil, bitrateKbps: Double? = nil,
                packetLossPercent: Double? = nil, roundTripMs: Double? = nil, isSimulated: Bool) {
        self.width = width; self.height = height; self.framesPerSecond = framesPerSecond
        self.bitrateKbps = bitrateKbps; self.packetLossPercent = packetLossPercent
        self.roundTripMs = roundTripMs; self.isSimulated = isSimulated
    }
}

public enum VideoCodec: String, Sendable { case h264, hevc }

public struct VideoFormat: Sendable, Equatable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public init(codec: VideoCodec, width: Int, height: Int) { self.codec = codec; self.width = width; self.height = height }
}

public struct EncodedVideoFrame: Sendable {
    public var data: Data            // one access unit, Annex-B
    public var isKeyframe: Bool
    public var presentationTimeUs: Int64
    public init(data: Data, isKeyframe: Bool, presentationTimeUs: Int64) {
        self.data = data; self.isKeyframe = isKeyframe; self.presentationTimeUs = presentationTimeUs
    }
}

public enum AudioEncoding: Sendable, Equatable {
    case opus
    /// Interleaved signed 16-bit little-endian PCM, already decoded by the transport.
    case pcmS16(channels: Int, sampleRate: Int)
}

public struct AudioFrame: Sendable {
    public var data: Data
    public var encoding: AudioEncoding
    public var presentationTimeUs: Int64
    public init(data: Data, encoding: AudioEncoding = .opus, presentationTimeUs: Int64) {
        self.data = data; self.encoding = encoding; self.presentationTimeUs = presentationTimeUs
    }
}

// MARK: - D. Display destinations

public struct DisplayCapabilities: Sendable, Equatable {
    public var codecs: [VideoCodec]
    public var maxWidth: Int
    public var maxHeight: Int
    public var maxFps: Int
    public init(codecs: [VideoCodec], maxWidth: Int, maxHeight: Int, maxFps: Int) {
        self.codecs = codecs; self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxFps = maxFps
    }
}

/// Where decoded gameplay ends up. The native mobile screen is the first destination.
/// Future browser receivers, external adapters and vehicle bridges implement this same
/// protocol; none of them exist yet.
public protocol DisplayDestination: AnyObject {
    var destinationID: String { get }
    var capabilities: DisplayCapabilities { get }
    func prepare(format: VideoFormat) throws
    func enqueue(video frame: EncodedVideoFrame)
    func enqueue(audio frame: AudioFrame)
    func setMuted(_ muted: Bool)
    func teardown()
}
