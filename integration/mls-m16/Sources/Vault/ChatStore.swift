#if DEBUG
// Legacy plaintext LAN demo; excluded from Release and unreachable from WatchlinkRootView.
import Foundation
import Observation

/// Holds the chat's message list and the logic for adding to it.
///
/// The list starts empty, appends every locally-composed message right away,
/// and — as of M2.1 — appends messages relayed from other
/// connected Watchlink clients. Outgoing text is also mirrored to the local relay
/// (see `RelayClient`) on a best-effort basis; the relay never affects local
/// behaviour, and if it is unavailable local chat is unchanged.
///
/// `@MainActor`: this is observable UI state, so every mutation happens on the
/// main actor. It also lets the relay's `@Sendable` receive handler capture
/// `self` safely.
@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage]

    @ObservationIgnored private let relay: any RelayTransport

    init(
        messages: [ChatMessage] = [],
        relay: any RelayTransport = RelayClient()
    ) {
        self.messages = messages
        self.relay = relay

        relay.onReceive { [weak self] text in
            Task { @MainActor in
                self?.appendRemote(text)
            }
        }
        relay.start()
    }

    /// Appends a message composed by the local user.
    ///
    /// Whitespace-only input is ignored so the caller doesn't have to guard.
    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(
            ChatMessage(
                text: text,
                isMine: true,
                time: ChatStore.timeFormatter.string(from: Date())
            )
        )

        // M2.1: mirror the same text to the local relay. Fire-and-forget — if
        // the relay is unavailable this is a silent no-op and local chat is
        // unaffected.
        relay.send(text: text)
    }

    /// Appends a message relayed from another connected client.
    ///
    /// The relay never echoes a frame back to its originator, so the local
    /// sender's own messages are not duplicated here — no client-side de-dup is
    /// needed.
    private func appendRemote(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(
            ChatMessage(
                text: text,
                isMine: false,
                time: ChatStore.timeFormatter.string(from: Date())
            )
        )
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

/// The three relay operations `ChatStore` uses. `RelayClient` is the only
/// production conformer; the protocol exists so tests can substitute a fake
/// transport without opening a socket.
protocol RelayTransport: AnyObject {
    func onReceive(_ handler: @escaping @Sendable (String) -> Void)
    func start()
    func send(text: String)
}

extension RelayClient: RelayTransport {}

#endif
