import Foundation
import Observation
import UIKit

/// Live message list for one pair, plus sending and lazy photo loading.
@MainActor @Observable
final class PairChatModel {
    private(set) var messages: [BackendMessage] = []
    private(set) var sending = false
    var errorMessage: String?
    /// Set when the partner sends a heartbeat while the app is open; the UI plays it.
    var incomingHeartbeat: Int?

    let pairID: String
    let myID: String
    private let backend: any ChatBackend
    @ObservationIgnored private var listener: (any ListenerToken)?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var firstSnapshot = true
    private let photoCache = NSCache<NSString, UIImage>()

    init(backend: any ChatBackend, pairID: String, myID: String) {
        self.backend = backend
        self.pairID = pairID
        self.myID = myID
    }

    func start() {
        guard listener == nil else { return }
        listener = backend.observeMessages(pairID: pairID, limit: 200) { [weak self] messages in
            Task { @MainActor in self?.apply(messages) }
        }
    }

    func stop() { listener?.cancel(); listener = nil }

    func isMine(_ message: BackendMessage) -> Bool { message.senderID == myID }

    // MARK: Sending

    func send(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await run { try await self.backend.sendText(trimmed, pairID: self.pairID) }
    }

    func send(photo data: Data) async {
        guard let image = UIImage(data: data), let jpeg = PhotoCompressor.jpeg(from: image) else {
            errorMessage = "Fotoğraf hazırlanamadı."
            return
        }
        await run { try await self.backend.sendPhoto(jpeg, pairID: self.pairID) }
    }

    func sendHeartbeat(bpm: Int) async {
        await run { try await self.backend.sendHeartbeat(bpm: bpm, pairID: self.pairID) }
    }

    // MARK: Photos

    func image(for photoID: String) async -> UIImage? {
        if let cached = photoCache.object(forKey: photoID as NSString) { return cached }
        guard let data = try? await backend.loadPhoto(photoID: photoID, pairID: pairID),
              let image = UIImage(data: data) else { return nil }
        photoCache.setObject(image, forKey: photoID as NSString)
        return image
    }

    // MARK: Internals

    private func apply(_ incoming: [BackendMessage]) {
        // A partner heartbeat that arrives after the first snapshot is "live".
        if !firstSnapshot {
            for message in incoming where !seen.contains(message.id) && message.senderID != myID {
                if case .heartbeat(let bpm) = message.kind { incomingHeartbeat = bpm }
            }
        }
        firstSnapshot = false
        seen.formUnion(incoming.map(\.id))
        messages = incoming
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        sending = true
        defer { sending = false }
        do { try await work() } catch { errorMessage = AppModel.describe(error) }
    }
}
