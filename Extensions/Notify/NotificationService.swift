import UserNotifications

/// Opens a Watchlink push on the phone.
///
/// The server side (Worker, Apple) only ever sees a generic alert, "Yeni bir
/// mesaj var 💌", plus the message still sealed. Here, on the recipient's
/// device, the pair key from the shared Keychain opens it and the banner
/// becomes the real preview. Özel Alan items stay generic on purpose, and
/// anything that can't be opened falls back to the generic text.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.content = content
        Self.reveal(into: content)
        contentHandler(content)
    }

    /// Out of time: deliver whatever is ready (the generic text at worst).
    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let content { contentHandler(content) }
    }

    static func reveal(into content: UNMutableNotificationContent) {
        guard let info = content.userInfo["wl"] as? [String: Any],
              let pairID = info["p"] as? String,
              let sender = info["s"] as? String,
              let messageID = info["m"] as? String,
              let shared = SharedPairKey.load(pairID: pairID) else { return }

        content.threadIdentifier = pairID
        if !shared.partnerName.isEmpty { content.title = shared.partnerName }

        guard let sealedText = info["c"] as? String,
              let sealed = Data(base64Encoded: sealedText) else { return }
        let session = PairCrypto.session(pairID: pairID, myID: shared.myID, keyData: shared.key)
        guard let plain = try? session.open(sealed, aad: session.messageAAD(id: messageID, sender: sender)),
              let payload = try? JSONDecoder().decode(SealedPayload.self, from: plain) else { return }

        switch payload.kind {
        case "text":
            if let text = payload.text, !text.isEmpty { content.body = String(text.prefix(240)) }
        case "photo":
            content.body = "📷 Bir fotoğraf gönderdi"
        case "heartbeat":
            content.body = payload.bpm.map { "💓 Kalp atışını gönderdi · \($0) BPM" } ?? "💓 Kalp atışını gönderdi"
            content.sound = UNNotificationSound(named: UNNotificationSoundName("heartbeat.wav"))
        case "voice":
            let seconds = Int((payload.seconds ?? 0).rounded())
            content.body = "🎤 Sesli mesaj · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        case "private":
            content.body = "🌙 Özel Alan'da bir şey var"
        default:
            break
        }
    }
}
