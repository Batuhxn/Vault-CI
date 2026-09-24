import XCTest

// Production sources are compiled into this (non-hosted) test bundle, so
// their internal types are in scope without `@testable import`.

/// Records what `ChatStore` asks of the relay; never opens a socket.
private final class FakeRelay: RelayTransport, @unchecked Sendable {
    private(set) var sent: [String] = []
    private(set) var startCount = 0
    private var handler: (@Sendable (String) -> Void)?

    func onReceive(_ handler: @escaping @Sendable (String) -> Void) { self.handler = handler }
    func start() { startCount += 1 }
    func send(text: String) { sent.append(text) }

    /// Simulates the relay delivering one decoded frame's text.
    func deliver(_ text: String) { handler?(text) }
}

@MainActor
final class ChatStoreTests: XCTestCase {
    private var relay: FakeRelay!
    private var store: ChatStore!

    override func setUp() async throws {
        relay = FakeRelay()
        store = ChatStore(messages: [], relay: relay)
    }

    func testInitRegistersHandlerAndStartsRelayOnce() {
        XCTAssertEqual(relay.startCount, 1)
    }

    func testDefaultStoreStartsEmpty() {
        XCTAssertTrue(ChatStore(relay: FakeRelay()).messages.isEmpty)
    }

    func testValidSendCreatesExactlyOneOutgoingMessageAndOneRelaySend() {
        store.send("hello")
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.text, "hello")
        XCTAssertEqual(store.messages.first?.isMine, true)
        XCTAssertEqual(relay.sent, ["hello"])
    }

    func testSendTrimsLeadingAndTrailingWhitespaceAndNewlines() {
        store.send("  \n\thi there \n ")
        XCTAssertEqual(store.messages.map(\.text), ["hi there"])
        XCTAssertEqual(relay.sent, ["hi there"])
    }

    func testSendKeepsInteriorWhitespace() {
        store.send("line one\nline two")
        XCTAssertEqual(relay.sent, ["line one\nline two"])
    }

    func testWhitespaceOnlySendCreatesNothingAndSendsNothing() {
        for input in ["", " ", "\n", " \t\r\n "] {
            store.send(input)
        }
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(relay.sent.isEmpty)
    }

    func testInboundMessageIsAppendedOnceAsNotMine() async {
        relay.deliver("  from peer ")
        await waitForMessageCount(1)
        XCTAssertEqual(store.messages.map(\.text), ["from peer"])
        XCTAssertEqual(store.messages.first?.isMine, false)
        XCTAssertTrue(relay.sent.isEmpty, "inbound text must not be echoed back to the relay")
    }

    func testWhitespaceOnlyInboundIsIgnored() async {
        relay.deliver("   ")
        relay.deliver("marker")
        await waitForMessageCount(1)
        XCTAssertEqual(store.messages.map(\.text), ["marker"])
    }

    /// `ChatStore` hops inbound text to the main actor via `Task`, so wait for
    /// it instead of assuming a scheduling order.
    private func waitForMessageCount(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where store.messages.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.messages.count, count, file: file, line: line)
    }
}
