#if DEBUG
// Legacy plaintext LAN demo; excluded from Release and unreachable from WatchlinkRootView.
import Foundation
import Network

/// Best-effort relay link for the M2.1 local chat test.
///
/// Sends and receives newline-delimited JSON lines over TCP to the host
/// described by `RelayConfiguration`, using Apple's Network.framework.
/// Everything here is intentionally forgiving: if the relay is down,
/// unreachable, or a send/receive fails, the error is logged and the link is
/// rebuilt. Nothing in this type throws to callers or crashes the app — local
/// chat must keep working with no relay present.
///
/// M2.1 scope only: plaintext, unauthenticated, no acknowledgement, no history,
/// no encryption. The relay forwards a client's frame to every *other* client;
/// a client never receives its own frame back.
///
/// `@unchecked Sendable`: mutable state (`connection`, `currentState`,
/// `decoder`, `messageHandler`, keep-alive/recovery flags) is confined to
/// the private serial `queue`; every other stored property is an immutable
/// value.
final class RelayClient: @unchecked Sendable {
    private let configuration: RelayConfiguration
    private let queue = DispatchQueue(label: "com.example.Vault.relay")

    /// The live connection, if any. Accessed only on `queue`.
    private var connection: NWConnection?
    /// Last observed state of `connection`. Accessed only on `queue`.
    private var currentState: NWConnection.State = .setup

    /// Bytes received from the current connection that have not yet been split
    /// into complete newline-delimited frames. Accessed only on `queue`.
    private var decoder = RelayFrameDecoder()

    /// Called with the `text` of every complete, valid frame received from the
    /// relay. Invoked on `queue`; the handler hops to whatever context it
    /// needs. Set via `onReceive(_:)`, read only on `queue`.
    private var messageHandler: (@Sendable (String) -> Void)?

    /// True once `start()` has run: "keep-alive" mode. The client keeps a
    /// connection up — re-establishing it after a drop, and replacing one that
    /// stays parked in `.waiting` — even when nothing is being sent, so a device
    /// that only listens still receives. Accessed only on `queue`.
    private var keepAlive = false
    /// Single-flight guard: true while one bounded recovery task is already
    /// scheduled, so repeated `.waiting`/failure callbacks cannot storm the
    /// queue with competing reconnects. Accessed only on `queue`.
    private var recoveryScheduled = false
    /// Delay before a scheduled recovery acts. Long enough that a transient
    /// `.waiting` (brief path change, DNS hiccup) can settle to `.ready` on its
    /// own without a needless rebuild; short enough that a listen-only device is
    /// never parked for long.
    private let recoveryDelay: TimeInterval = 3

    init(configuration: RelayConfiguration = .default) {
        self.configuration = configuration
    }

    /// Eagerly opens the connection and begins receiving, so this client picks
    /// up relayed messages even if it never sends one. Safe to call once at
    /// startup; further calls are harmless.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.keepAlive = true
            _ = self.usableConnection()
        }
    }

    /// Registers the handler invoked for each complete, valid received frame's
    /// text. The handler runs on the relay's internal queue.
    func onReceive(_ handler: @escaping @Sendable (String) -> Void) {
        queue.async { [weak self] in
            self?.messageHandler = handler
        }
    }

    /// Queues `text` for delivery to the relay as a single JSON line.
    ///
    /// Returns immediately. Delivery happens on a background queue and any
    /// failure is logged and discarded.
    func send(text: String) {
        let frame = RelayMessage(text: text, sentAt: Date())

        queue.async { [weak self] in
            self?.deliver(frame)
        }
    }

    // MARK: - Delivery (send path — unchanged behaviour)

    private func deliver(_ message: RelayMessage) {
        let line: Data
        do {
            line = try Self.encodeFrame(message)
        } catch {
            log("encode failed: \(error)")
            return
        }

        let connection = usableConnection()
        connection.send(content: line, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }
            self.log("send failed: \(error)")
            self.resetConnection()
        })
    }

    /// Serialises one outbound frame: sorted-key JSON, ISO-8601 `sentAt`,
    /// trailing `\n`. Internal (not private) only so tests can pin the wire
    /// format.
    static func encodeFrame(text: String, sentAt: Date) throws -> Data {
        try encodeFrame(RelayMessage(text: text, sentAt: sentAt))
    }

    private static func encodeFrame(_ message: RelayMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(message) + Data([0x0A]) // trailing "\n"
    }

    /// Returns a connection that can carry a new send, creating one if needed.
    ///
    /// A connection is only reused while it is healthy (`.ready`, or still
    /// coming up). A connection sitting in `.waiting` — which on iOS can mean the
    /// local-network path never resolved for this socket even after permission
    /// was granted — or one that is `.failed`/`.cancelled` is replaced, so a new
    /// message is never silently buffered onto a socket that will never send.
    /// This send-path logic is unchanged. A `.waiting` connection is not torn
    /// down here — it is only declined for *reuse*; the state handler owns the
    /// separate bounded recovery for a socket that stays parked (see
    /// `scheduleRecovery`).
    private func usableConnection() -> NWConnection {
        if let connection {
            switch currentState {
            case .ready, .preparing, .setup:
                return connection
            default:
                connection.cancel()
                self.connection = nil
            }
        }
        return makeConnection()
    }

    private func makeConnection() -> NWConnection {
        currentState = .setup
        decoder = RelayFrameDecoder()

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(configuration.host),
            port: NWEndpoint.Port(rawValue: configuration.port) ?? .any
        )
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.currentState = state
            switch state {
            case .waiting(let error):
                // Often transient: give it a chance to settle to `.ready` on
                // its own. In keep-alive mode, arm one bounded check so a
                // listen-only device is never parked here forever (see
                // `scheduleRecovery`). The send path's `usableConnection()`
                // is unaffected and still replaces a `.waiting` socket on the
                // next send exactly as before.
                self.log("connection waiting: \(error)")
                self.scheduleRecovery()
            case .failed(let error):
                self.log("connection failed: \(error)")
                self.resetConnection()
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive(on: connection)
        return connection
    }

    /// Tears down the current connection. `reconnect` schedules a bounded
    /// recovery afterwards (the default — used by `.failed`, send failure, and
    /// receive failure); the `.waiting` recovery path passes `false` because it
    /// rebuilds immediately itself.
    private func resetConnection(reconnect: Bool = true) {
        connection?.cancel()
        connection = nil
        currentState = .cancelled
        decoder = RelayFrameDecoder()
        if reconnect {
            scheduleRecovery()
        }
    }

    // MARK: - Receive path

    /// Arms one `receive` on `connection`. On completion the bytes are fed to
    /// `decoder`, every complete `\n`-delimited frame is decoded and
    /// dispatched, and — unless the stream ended or errored — another `receive`
    /// is armed. A single callback may carry zero, part of one, or several
    /// frames; none of those cases is assumed. Callbacks from a connection that
    /// has since been replaced are ignored.
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard connection === self.connection else { return }

            if let data, !data.isEmpty {
                self.dispatch(self.decoder.append(data))
            }

            if let error {
                self.log("receive failed: \(error)")
                self.resetConnection()
                return
            }
            if isComplete {
                self.log("receive stream ended")
                self.resetConnection()
                return
            }
            self.receive(on: connection)
        }
    }

    /// Hands each decoded frame to the handler, in arrival order. Anything
    /// that is not a JSON object carrying a non-empty `text` is logged and
    /// dropped — a malformed frame must never crash the app or stop the
    /// receive loop.
    private func dispatch(_ frames: [RelayFrameDecoder.Frame]) {
        for frame in frames {
            switch frame {
            case .text(let text):
                messageHandler?(text)
            case .malformed(let byteCount):
                log("ignored malformed frame (\(byteCount) bytes)")
            }
        }
    }

    // MARK: - Recovery (keep-alive mode: listeners survive a drop or a park)

    /// Schedules the single bounded recovery task, if keep-alive mode is on and
    /// one is not already pending. Both triggers — a torn-down connection
    /// (`resetConnection`) and a connection parked in `.waiting` (state handler)
    /// — funnel through here, so there is exactly one retry mechanism and it
    /// cannot storm: repeated callbacks while `recoveryScheduled` is `true` are
    /// no-ops. The pure sender (which never calls `start()`, so `keepAlive` is
    /// `false`) schedules nothing — its `usableConnection()` behaviour is
    /// untouched.
    private func scheduleRecovery() {
        guard keepAlive, !recoveryScheduled else { return }
        recoveryScheduled = true
        let parked = connection
        queue.asyncAfter(deadline: .now() + recoveryDelay) { [weak self] in
            guard let self else { return }
            self.recoveryScheduled = false
            self.recover(parked: parked)
        }
    }

    /// Runs `recoveryDelay` after a recovery was scheduled, on `queue`.
    ///
    /// - If `parked` is still the current connection and is still `.waiting`,
    ///   it never came up: replace it. A connection that reached `.ready`
    ///   (or was already swapped out by a send / `.failed` / an earlier
    ///   recovery) fails the identity or state check and is left alone — a
    ///   stale task can never reset a newer connection.
    /// - Then, in keep-alive mode, guarantee the cycle ends with a live or
    ///   in-progress connection (covers the torn-down case, and a race where
    ///   `.failed` nilled the connection while this task was pending).
    private func recover(parked: NWConnection?) {
        if let parked, parked === connection, case .waiting = currentState {
            log("waiting recovery: replacing parked connection")
            resetConnection(reconnect: false)
        }
        if keepAlive, connection == nil {
            _ = usableConnection()
        }
    }

    private func log(_ message: String) {
        print("[relay] \(message)")
    }
}

/// One outbound relay frame, serialised as newline-delimited JSON, e.g.
/// `{"sentAt":"2026-09-08T05:30:00Z","text":"hello captain","type":"message"}`.
private struct RelayMessage: Encodable {
    let type = "message"
    let text: String
    let sentAt: Date
}

/// Splits a byte stream on `\n` into frames and decodes each one. A single
/// `append` may carry zero, part of one, or several frames; a partial trailing
/// frame stays buffered for the next call. Whitespace-only frames (space, tab,
/// CR) are skipped silently.
///
/// Pure value type, extracted from `RelayClient` so framing can be unit
/// tested without a socket. `RelayClient` confines its instance to `queue`.
struct RelayFrameDecoder {
    enum Frame: Equatable {
        case text(String)
        case malformed(byteCount: Int)
    }

    private var buffer = Data()

    mutating func append(_ data: Data) -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        let newline: UInt8 = 0x0A
        while let index = buffer.firstIndex(of: newline) {
            let frame = Data(buffer.prefix(upTo: index))
            buffer = Data(buffer.suffix(from: buffer.index(after: index)))
            if let decoded = Self.decode(frame) {
                frames.append(decoded)
            }
        }
        return frames
    }

    /// `nil` for a whitespace-only frame; `.malformed` for anything that is not
    /// a JSON object carrying a non-empty `text`.
    static func decode(_ frame: Data) -> Frame? {
        let isAllWhitespace = !frame.contains { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }
        guard !isAllWhitespace else { return nil }

        guard
            let incoming = try? JSONDecoder().decode(IncomingRelayMessage.self, from: frame),
            !incoming.text.isEmpty
        else {
            return .malformed(byteCount: frame.count)
        }
        return .text(incoming.text)
    }
}

/// The fields Watchlink reads from an inbound relay frame. `type` and `sentAt`
/// are accepted on the wire but ignored here: M2.1 only needs the text.
private struct IncomingRelayMessage: Decodable {
    let text: String
}

#endif
