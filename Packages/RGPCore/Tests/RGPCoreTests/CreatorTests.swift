import XCTest
@testable import RGPCore

final class CreatorTests: XCTestCase {
    func testPrivacySceneAlwaysWins() {
        XCTAssertEqual(PublicScene.effective(chosen: .beRightBack, gameplayArriving: true), .beRightBack)
        XCTAssertEqual(PublicScene.effective(chosen: .beRightBack, gameplayArriving: false), .beRightBack)
    }

    func testLostGameplayShowsReconnectingNotAFrozenPicture() {
        XCTAssertEqual(PublicScene.effective(chosen: .gameplay, gameplayArriving: false), .reconnecting)
        XCTAssertEqual(PublicScene.effective(chosen: .gameplay, gameplayArriving: true), .gameplay)
    }

    func testEverySceneExceptGameplayHidesTheGame() {
        for scene in PublicScene.allCases { XCTAssertEqual(scene.hidesGameplay, scene != .gameplay) }
    }

    func testTransportStreamPacketsAreWellFormed() {
        var mux = MPEGTSMuxer(hasAudio: true)
        var stream = mux.tables()
        for i in 0..<40 {
            let picture = Data([0, 0, 0, 1, 0x65] + [UInt8](repeating: UInt8(i), count: 37 + i * 191))
            stream += mux.video(annexB: picture, pts90k: UInt64(i) * 3000, isKeyframe: i == 0)
            stream += mux.audio(adts: MPEGTSMuxer.adtsHeader(frameLength: 200, sampleRate: 48000, channels: 2) + Data(repeating: 1, count: 200), pts90k: UInt64(i) * 3000)
        }
        XCTAssertEqual(stream.count % 188, 0)
        var last: [Int: Int] = [:]
        for start in stride(from: 0, to: stream.count, by: 188) {
            XCTAssertEqual(stream[start], 0x47)
            let pid = Int(stream[start + 1] & 0x1F) << 8 | Int(stream[start + 2])
            let counter = Int(stream[start + 3] & 0x0F)
            if let previous = last[pid] { XCTAssertEqual(counter, (previous + 1) & 0x0F, "continuity on pid \(pid)") }
            last[pid] = counter
        }
        XCTAssertEqual(Set(last.keys), [0, 0x1000, 0x100, 0x101])
    }

    func testChecksumMatchesKnownValue() {
        // MPEG-2 CRC of "123456789" is 0x0376E6E7.
        XCTAssertEqual(MPEGTSMuxer.crc(Array("123456789".utf8)), [0x03, 0x76, 0xE6, 0xE7])
    }

    func testADTSHeaderCarriesTheFrameLength() {
        let header = [UInt8](MPEGTSMuxer.adtsHeader(frameLength: 300, sampleRate: 48000, channels: 2))
        XCTAssertEqual(header.count, 7)
        let length = (Int(header[3] & 3) << 11) | (Int(header[4]) << 3) | (Int(header[5]) >> 5)
        XCTAssertEqual(length, 307)
        XCTAssertEqual((header[2] >> 2) & 0x0F, 3)   // 48 kHz
    }

    func testOBSAuthenticationIsDeterministicAndHidesThePassword() {
        let a = OBSProtocol.authentication(password: "pw", salt: "salt", challenge: "challenge")
        XCTAssertEqual(a, OBSProtocol.authentication(password: "pw", salt: "salt", challenge: "challenge"))
        XCTAssertNotEqual(a, OBSProtocol.authentication(password: "pw2", salt: "salt", challenge: "challenge"))
        XCTAssertFalse(a.contains("pw"))
        XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
    }

    func testOBSMessagesRoundTrip() {
        let text = String(decoding: OBSProtocol.request("SetCurrentProgramScene", id: "7", data: ["sceneName": "BRB"]), as: UTF8.self)
        XCTAssertTrue(text.contains("\"op\":6"))
        XCTAssertTrue(text.contains("BRB"))
        if case .hello(let salt, let challenge) = OBSProtocol.parse(#"{"op":0,"d":{"rpcVersion":1,"authentication":{"salt":"s","challenge":"c"}}}"#) {
            XCTAssertEqual(salt, "s"); XCTAssertEqual(challenge, "c")
        } else { XCTFail("hello not read") }
        if case .response(let type, let id, let ok, _, let data) = OBSProtocol.parse(#"{"op":7,"d":{"requestType":"GetRecordStatus","requestId":"3","requestStatus":{"result":true,"code":100},"responseData":{"outputActive":true}}}"#) {
            XCTAssertEqual(type, "GetRecordStatus"); XCTAssertEqual(id, "3"); XCTAssertTrue(ok)
            XCTAssertEqual(data["outputActive"] as? Bool, true)
        } else { XCTFail("response not read") }
        if case .unknown = OBSProtocol.parse("not json") {} else { XCTFail() }
    }

    func testHighlightClipRangeStaysInsideTheRecording() {
        XCTAssertEqual(HighlightMarker(seconds: 100).clipRange(length: 30, recordingDuration: 300), 70...100)
        XCTAssertEqual(HighlightMarker(seconds: 10).clipRange(length: 30, recordingDuration: 300), 0...10)
        XCTAssertEqual(HighlightMarker(seconds: 400).clipRange(length: 60, recordingDuration: 300), 240...300)
    }
}
