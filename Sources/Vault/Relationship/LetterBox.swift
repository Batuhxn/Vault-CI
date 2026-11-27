import Foundation
import Observation

/// A note to the partner, read once at the end of their welcome and kept in Biz.
struct SealedLetter: Codable, Equatable {
    var text: String
    var at: Date
}

/// One note each way. Mine is written on this phone (it may be written before
/// pairing) and stays here; whenever a pair is linked it is sealed with the pair
/// key and published, so a note written ahead reaches a partner the moment you
/// pair. The partner's note is only ever held sealed on the server.
@MainActor @Observable
final class LetterBox {
    static let shared = LetterBox()
    static let maxLength = 2_000

    private(set) var mine: SealedLetter?
    private(set) var partners: SealedLetter?
    /// When this phone last opened the partner's note (seconds since 1970, per pair).
    private var openedAt: Double = 0

    @ObservationIgnored private var link: (backend: any ChatBackend, pairID: String, myID: String,
                                           partnerID: String?, session: PairCrypto.Session)?
    @ObservationIgnored private var listener: (any ListenerToken)?
    @ObservationIgnored private var lastPublished: SealedLetter?
    @ObservationIgnored private var ephemeral = false

    private init() {
        mine = Self.load()
    }

    var pairID: String? { link?.pairID }

    // MARK: Pair link

    func attach(backend: any ChatBackend, pairID: String, myID: String, partnerID: String?, session: PairCrypto.Session) {
        detach()
        link = (backend, pairID, myID, partnerID, session)
        if let partnerID {
            listener = backend.observeMemberDoc(collection: "letter", pairID: pairID, member: partnerID) { [weak self] sealed, _ in
                Task { @MainActor in self?.receive(sealed) }
            }
        }
        openedAt = UserDefaults.standard.double(forKey: "wl.letter.opened.\(pairID)")
        lastPublished = nil
        publish()
    }

    func detach() {
        listener?.cancel()
        listener = nil
        link = nil
        partners = nil
    }

    // MARK: Writing

    func save(_ text: String) {
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength))
        guard trimmed != mine?.text else { return }
        mine = trimmed.isEmpty ? nil : SealedLetter(text: trimmed, at: Date())
        persist()
        publish()
    }

    private func publish() {
        // An emptied note is kept on the server as an empty text, so the partner stops seeing it.
        guard let link else { return }
        let letter = mine ?? SealedLetter(text: "", at: Date(timeIntervalSince1970: 0))
        guard letter != lastPublished, mine != nil || lastPublished != nil,
              let data = try? JSONEncoder().encode(letter),
              let sealed = try? link.session.seal(data, aad: link.session.letterAAD(of: link.myID)),
              sealed.count <= 16 * 1024 else { return }
        lastPublished = letter
        let backend = link.backend, pairID = link.pairID
        Task { try? await backend.setMemberDoc(sealed, collection: "letter", pairID: pairID) }
    }

    private func receive(_ sealed: Data?) {
        guard let sealed, let link, let partnerID = link.partnerID,
              let data = try? link.session.open(sealed, aad: link.session.letterAAD(of: partnerID)),
              let letter = try? JSONDecoder().decode(SealedLetter.self, from: data) else { return }
        partners = letter.text.isEmpty ? nil : letter
    }

    // MARK: Opened state (per pair, on this phone)

    /// The partner's note exists and this phone has not opened it (or its latest version) yet.
    var unopened: Bool {
        guard let partners else { return false }
        return openedAt < partners.at.timeIntervalSince1970
    }

    func markOpened() {
        guard let partners, let link else { return }
        openedAt = partners.at.timeIntervalSince1970
        if !ephemeral { UserDefaults.standard.set(openedAt, forKey: "wl.letter.opened.\(link.pairID)") }
    }

    // MARK: Storage

    private static var fileURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("watchlink-letter.json")
    }

    private static func load() -> SealedLetter? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SealedLetter.self, from: data)
    }

    private func persist() {
        guard !ephemeral, let url = Self.fileURL else { return }
        if let mine, let data = try? JSONEncoder().encode(mine) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    #if DEBUG
    /// Demo mode: a note of my own (not saved to disk).
    func useDemo(mine text: String) {
        ephemeral = true
        mine = SealedLetter(text: text, at: Date())
    }
    #endif
}

enum Turkish {
    /// "Batuhan" → "Batuhan'ın", "Elif" → "Elif'in", "Ada" → "Ada'nın", "Öykü" → "Öykü'nün".
    static func genitive(_ name: String) -> String {
        let lower = name.lowercased(with: Locale(identifier: "tr_TR"))
        guard let vowel = lower.last(where: { "aıoueiöü".contains($0) }) else { return name + "'in" }
        let suffix: String
        switch vowel {
        case "a", "ı": suffix = "ın"
        case "e", "i": suffix = "in"
        case "o", "u": suffix = "un"
        default: suffix = "ün"
        }
        let endsInVowel = lower.last.map { "aıoueiöü".contains($0) } ?? false
        return name + "'" + (endsInVowel ? "n" : "") + suffix
    }
}
