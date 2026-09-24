import XCTest

// Production sources are compiled into this (non-hosted) test bundle, so
// their internal types are in scope without `@testable import`.

/// Pins the current M2.1 relay framing and wire format. These are behaviour
/// locks for the plaintext prototype, not security properties.
final class RelayFrameDecoderTests: XCTestCase {
    private func bytes(_ string: String) -> Data { Data(string.utf8) }

    func testValidFrameProducesExactlyOneMessage() {
        var decoder = RelayFrameDecoder()
        let frames = decoder.append(bytes(#"{"sentAt":"t","text":"hello","type":"message"}"# + "\n"))
        XCTAssertEqual(frames, [.text("hello")])
    }

    func testFrameSplitAcrossChunksIsReassembled() {
        var decoder = RelayFrameDecoder()
        XCTAssertEqual(decoder.append(bytes(#"{"text":"hel"#)), [])
        XCTAssertEqual(decoder.append(bytes(#"lo wor"#)), [])
        XCTAssertEqual(decoder.append(bytes(#"ld"}"# + "\n")), [.text("hello world")])
    }

    func testTwoFramesInOneChunkAreBothDecodedInOrder() {
        var decoder = RelayFrameDecoder()
        let frames = decoder.append(bytes(#"{"text":"one"}"# + "\n" + #"{"text":"two"}"# + "\n"))
        XCTAssertEqual(frames, [.text("one"), .text("two")])
    }

    func testPartialTrailingFrameStaysBuffered() {
        var decoder = RelayFrameDecoder()
        XCTAssertEqual(decoder.append(bytes(#"{"text":"one"}"# + "\n" + #"{"text":"tw"#)), [.text("one")])
        XCTAssertEqual(decoder.append(bytes(#"o"}"# + "\n")), [.text("two")])
    }

    func testMalformedJSONDoesNotProduceAMessage() {
        var decoder = RelayFrameDecoder()
        let garbage = "not json at all"
        XCTAssertEqual(decoder.append(bytes(garbage + "\n")), [.malformed(byteCount: garbage.utf8.count)])
    }

    func testMalformedFrameDoesNotStopLaterFrames() {
        var decoder = RelayFrameDecoder()
        let frames = decoder.append(bytes("{oops\n" + #"{"text":"after"}"# + "\n"))
        XCTAssertEqual(frames, [.malformed(byteCount: 5), .text("after")])
    }

    func testFramesWithoutUsableTextAreMalformed() {
        for frame in [#"{"text":""}"#, #"{"type":"message"}"#, #"{"text":42}"#, "[1,2]", "\"text\""] {
            XCTAssertEqual(
                RelayFrameDecoder.decode(bytes(frame)),
                .malformed(byteCount: frame.utf8.count),
                frame
            )
        }
    }

    func testWhitespaceOnlyFramesAreSkippedSilently() {
        var decoder = RelayFrameDecoder()
        XCTAssertEqual(decoder.append(bytes("\n \n\t\r\n")), [])
    }

    func testWhitespaceTextIsPassedThroughForChatStoreToReject() {
        // The decoder only rejects an *empty* text; trimming is ChatStore's job
        // (see ChatStoreTests.testWhitespaceOnlyInboundIsIgnored).
        XCTAssertEqual(RelayFrameDecoder.decode(bytes(#"{"text":"   "}"#)), .text("   "))
    }

    func testOutboundFrameWireFormatIsUnchanged() throws {
        let sentAt = Date(timeIntervalSince1970: 1_788_845_400) // 2026-09-08T05:30:00Z
        let frame = try RelayClient.encodeFrame(text: "hello captain", sentAt: sentAt)
        XCTAssertEqual(
            String(decoding: frame, as: UTF8.self),
            #"{"sentAt":"2026-09-08T05:30:00Z","text":"hello captain","type":"message"}"# + "\n"
        )
    }

    func testOutboundFrameRoundTripsThroughDecoder() throws {
        var decoder = RelayFrameDecoder()
        let frame = try RelayClient.encodeFrame(text: "round trip", sentAt: Date())
        XCTAssertEqual(decoder.append(frame), [.text("round trip")])
    }
}
