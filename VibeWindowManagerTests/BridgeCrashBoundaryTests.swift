import Foundation
import Testing
@testable import VibeWindowManager

struct BridgeCrashBoundaryTests {
    @Test(arguments: [UInt64.max, UInt64(Int.max), UInt64(Int.max - 1), UInt64(1) << 63])
    func oversizedFrameLengthClosesWithoutIndexingPayload(length: UInt64) {
        for masked in [false, true] {
            var buffer = Data([0x81, masked ? 0xff : 0x7f])
            for shift in stride(from: 56, through: 0, by: -8) {
                buffer.append(UInt8(truncatingIfNeeded: length >> shift))
            }
            var texts: [String] = []
            var closed = false
            VibeWebSocketFraming.readClientFrames(from: &buffer, outStrings: &texts, clientClosed: &closed)
            #expect(closed)
            #expect(texts.isEmpty)
            #expect(buffer.isEmpty)
        }
    }

    @Test func partialExtendedFrameHeadersRemainBuffered() {
        let cases: [[UInt8]] = [[0x81], [0x81, 126], [0x81, 126, 0], [0x81, 127], [0x81, 127, 0, 0, 0, 0, 0, 0, 0]]
        for bytes in cases {
            var buffer = Data(bytes)
            var texts: [String] = []
            var closed = false
            VibeWebSocketFraming.readClientFrames(from: &buffer, outStrings: &texts, clientClosed: &closed)
            #expect(buffer == Data(bytes))
            #expect(texts.isEmpty)
            #expect(!closed)
        }
    }

    @Test func invalidUTF8FrameDoesNotPoisonFollowingValidFrame() {
        var buffer = Data([0x81, 2, 0xc3, 0x28])
        buffer.append(VibeWebSocketFraming.encodeTextFrame("日本語 👨‍👩‍👧‍👦"))
        var texts: [String] = []
        var closed = false
        VibeWebSocketFraming.readClientFrames(from: &buffer, outStrings: &texts, clientClosed: &closed)
        #expect(texts == ["日本語 👨‍👩‍👧‍👦"])
        #expect(buffer.isEmpty)
    }

    @Test(arguments: [0, 125, 126, 65535, 65536])
    func framePayloadLengthTransitionsRoundTrip(length: Int) {
        let text = String(repeating: "x", count: length)
        var buffer = VibeWebSocketFraming.encodeTextFrame(text)
        var texts: [String] = []
        var closed = false
        VibeWebSocketFraming.readClientFrames(from: &buffer, outStrings: &texts, clientClosed: &closed)
        #expect(texts == [text])
        #expect(buffer.isEmpty)
    }

    @Test func httpParserAcceptsNonzeroDataStartIndexAndPreservesBody() {
        let data = Data("discardGET /bridge HTTP/1.1\r\nHost: localhost\r\n\r\nbody".utf8)
        var buffer = data.dropFirst(7)
        #expect(buffer.startIndex != 0)
        let request = HTTPRequestParser.firstRequest(from: &buffer)
        #expect(request?.method == "GET")
        #expect(request?.path == "/bridge")
        #expect(request?.headerFields["host"] == "localhost")
        #expect(String(data: buffer, encoding: .utf8) == "body")
    }

    @Test func successiveHTTPRequestsAfterBufferConsumption() {
        var buffer = Data("GET /one HTTP/1.1\r\n\r\nGET /two HTTP/1.1\r\n\r\n".utf8)
        #expect(HTTPRequestParser.firstRequest(from: &buffer)?.path == "/one")
        #expect(HTTPRequestParser.firstRequest(from: &buffer)?.path == "/two")
        #expect(buffer.isEmpty)
    }

    @Test func invalidUTF8HeaderConsumedWithoutDamagingFollowingRequest() {
        var buffer = Data([0xff, 13, 10, 13, 10])
        buffer.append(Data("GET /bridge HTTP/1.1\r\n\r\n".utf8))
        #expect(HTTPRequestParser.firstRequest(from: &buffer) == nil)
        #expect(HTTPRequestParser.firstRequest(from: &buffer)?.path == "/bridge")
    }

    @Test(arguments: [Int.min, -1, 0, 1, 2, 3, 4, 5, 6, 7, Int.max])
    func terminalSuffixHandlesEveryUTF8CutAndExtremeLimit(limit: Int) {
        let input = "Aé€😀"
        let result = TmuxPaneCapture.utf8ByteSuffix(input, maxBytes: limit)
        #expect(result.0.utf8.count <= max(0, limit))
        #expect(result.0.unicodeScalars.allSatisfy { $0.value != 0xfffd })
        #expect(Array(input.utf8).suffix(result.0.utf8.count).elementsEqual(result.0.utf8))
        #expect(result.1 == (limit < input.utf8.count))
    }

    @Test func extremeLineLimitsDoNotOverflow() {
        let low = TmuxPaneCapture.applyLineAndByteLimits("old\nnew", lineLimit: Int.min)
        #expect(low.text == "new")
        #expect(low.truncated)
        let high = TmuxPaneCapture.applyLineAndByteLimits("old\nnew", lineLimit: Int.max, maxBytes: Int.max)
        #expect(high.text == "old\nnew")
        #expect(!high.truncated)
    }

    @Test(arguments: ["", "null", "[]", "{", "{\"type\":false}", "{\"type\":\"ping\",\"t\":9223372036854775808}", "{\"type\":\"requestTmuxPane\",\"lines\":1e300}", "{\"type\":\"windowStreamClick\",\"windowId\":\"x\",\"nx\":1e400,\"ny\":0}"])
    func malformedBridgeRequestsThrowInsteadOfCrashing(json: String) {
        #expect(throws: (any Error).self) { try decodeClientMessage(from: json) }
    }

    @Test func unicodePastePayloadPreservesControlCharacters() throws {
        let input = BridgePasteText(type: "pasteText", text: "\0\n👨‍👩‍👧‍👦e\u{301}日本語")
        let data = try JSONEncoder().encode(input)
        let decoded = try decodeClientMessage(from: String(decoding: data, as: UTF8.self)) as? BridgePasteText
        #expect(decoded?.text == input.text)
    }
}
