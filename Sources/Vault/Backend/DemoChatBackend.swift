#if DEBUG
import CryptoKit
import Foundation
import UIKit

/// Demo mode: launched with `-WLDemo` (the simulator UI tour). No network,
/// no Firebase: an in-memory pair with a realistic conversation, so every
/// screen can be photographed and checked.
///
/// Everything still goes through the real end-to-end path: the partner is a
/// second X25519 identity, each item is sealed with `PairCrypto` under the
/// same additional data the app checks, and the app opens it like any other.
enum DemoMode {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-WLDemo") }
}

@MainActor
final class DemoChatBackend: ChatBackend {
    static let me = "demo-me"
    static let partner = "demo-elif"
    static let pairID = "demopair"

    private(set) var currentUserID: String? = DemoChatBackend.me

    private var pair: PairInfo
    private let session: PairCrypto.Session
    private var messages: [BackendMessage] = []
    private var blobs: [String: Data] = [:]
    private var memberDocs: [String: (Data, Date)] = [:]
    private var messageObservers: [UUID: ([BackendMessage]) -> Void] = [:]
    private var pairObservers: [UUID: (PairInfo) -> Void] = [:]
    private var docObservers: [UUID: (key: String, onChange: (Data?, Date?) -> Void)] = [:]
    private var partnerTypingBeat: Task<Void, Never>?

    init() {
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let theirs = Curve25519.KeyAgreement.PrivateKey()
        PairCrypto.demoIdentities[Self.me] = mine
        let keys = [Self.me: mine.publicKey.rawRepresentation, Self.partner: theirs.publicKey.rawRepresentation]
        pair = PairInfo(id: Self.pairID, memberIDs: [Self.me, Self.partner], publicKeys: keys)
        // swiftlint:disable:next force_try
        session = try! PairCrypto.session(pairID: Self.pairID, myID: Self.me, partnerID: Self.partner, publicKeys: keys)
        seed()
    }

    // MARK: Sign-in and pairing (already paired)

    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async throws {}
    func signInForTesting() async throws {}
    func signOut() throws {}
    func createPair(publicKey: Data) async throws -> (code: String, pairID: String) { throw BackendError.pairFull }
    func joinPair(code: String, publicKey: Data) async throws { throw BackendError.pairFull }
    func currentPairs() async throws -> [PairInfo] { [pair] }

    func observePair(_ pairID: String, onChange: @escaping (PairInfo) -> Void) -> ListenerToken {
        let id = UUID()
        pairObservers[id] = onChange
        let pair = self.pair
        Task { @MainActor in onChange(pair) }
        return DemoToken { [weak self] in self?.pairObservers[id] = nil }
    }

    // MARK: Messages

    func observeMessages(pairID: String, limit: Int, onChange: @escaping ([BackendMessage]) -> Void) -> ListenerToken {
        let id = UUID()
        messageObservers[id] = onChange
        let current = Array(messages.suffix(limit))
        Task { @MainActor in onChange(current) }
        return DemoToken { [weak self] in self?.messageObservers[id] = nil }
    }

    func sendSealed(_ sealed: Data, id: String, pairID: String) async throws {
        try? await Task.sleep(for: .milliseconds(150))
        messages.append(BackendMessage(id: id, senderID: Self.me, sealed: sealed, createdAt: Date()))
        emitMessages()
        // The partner "reads" it a moment later, so "Görüldü" can be seen.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.publishPartnerPresence(typing: false, read: id)
        }
    }

    func uploadSealedPhoto(_ sealed: Data, id: String, pairID: String) async throws { blobs[id] = sealed }

    func loadSealedPhoto(id: String, pairID: String) async throws -> Data {
        guard let blob = blobs[id] else { throw BackendError.noPair }
        return blob
    }

    func saveSealedProfile(_ sealed: Data, pairID: String) async throws {
        pair.sealedProfiles[Self.me] = sealed
        let pair = self.pair
        pairObservers.values.forEach { $0(pair) }
    }

    // MARK: Member documents (presence, agenda)

    func setMemberDoc(_ sealed: Data, collection: String, pairID: String) async throws {
        setDoc(sealed, key: "\(collection)/\(Self.me)")
    }

    func observeMemberDoc(collection: String, pairID: String, member: String,
                          onChange: @escaping (Data?, Date?) -> Void) -> ListenerToken {
        let key = "\(collection)/\(member)"
        let id = UUID()
        docObservers[id] = (key, onChange)
        if let current = memberDocs[key] {
            Task { @MainActor in onChange(current.0, current.1) }
        }
        return DemoToken { [weak self] in self?.docObservers[id] = nil }
    }

    func setPresence(_ sealed: Data, pairID: String) async throws {
        try await setMemberDoc(sealed, collection: "presence", pairID: pairID)
    }

    func observePresence(pairID: String, member: String, onChange: @escaping (Data?, Date?) -> Void) -> ListenerToken {
        observeMemberDoc(collection: "presence", pairID: pairID, member: member, onChange: onChange)
    }

    func idToken() async throws -> String { throw BackendError.notSignedIn }  // no pushes in demo mode

    // MARK: Internals

    private func emitMessages() {
        let current = messages
        messageObservers.values.forEach { $0(current) }
    }

    private func setDoc(_ sealed: Data, key: String) {
        let entry = (sealed, Date())
        memberDocs[key] = entry
        for observer in docObservers.values where observer.key == key { observer.onChange(entry.0, entry.1) }
    }

    private func seal<T: Encodable>(_ value: T, aad: String) -> Data {
        // swiftlint:disable:next force_try
        try! session.seal(try! JSONEncoder().encode(value), aad: aad)
    }

    private func add(_ payload: SealedPayload, from sender: String, at date: Date, id: String = UUID().uuidString) {
        let sealed = seal(payload, aad: session.messageAAD(id: id, sender: sender))
        messages.append(BackendMessage(id: id, senderID: sender, sealed: sealed, createdAt: date))
    }

    private func publishPartnerPresence(typing: Bool, read: String?) {
        let presence = SealedPresence(typing: typing, here: true, read: read)
        setDoc(seal(presence, aad: session.presenceAAD(of: Self.partner)), key: "presence/\(Self.partner)")
    }

    // MARK: The conversation

    private func seed() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = today.addingTimeInterval(-86_400)
        func at(_ day: Date, _ hour: Int, _ minute: Int) -> Date {
            // Keep "today" in the past even when the tour runs early in the morning.
            min(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day, now.addingTimeInterval(-60))
        }
        let p = Self.partner, m = Self.me

        pair.sealedProfiles[p] = seal(SealedProfile(name: "Elif", bpm: 76), aad: session.profileAAD(of: p))
        pair.sealedProfiles[m] = seal(SealedProfile(name: "Batuhan", bpm: 69), aad: session.profileAAD(of: m))

        add(SealedPayload(kind: "text", text: "Bugün ders çok uzundu ya 😮‍💨"), from: p, at: at(yesterday, 21, 40))
        add(SealedPayload(kind: "text", text: "Akşam biraz yürüyelim mi? Kafanı dağıtırsın"), from: m, at: at(yesterday, 21, 42))
        let olur = UUID().uuidString
        add(SealedPayload(kind: "text", text: "Olur 🫶"), from: p, at: at(yesterday, 21, 43), id: olur)

        let photoID = UUID().uuidString
        blobs[photoID] = (try? session.seal(Self.photo(), aad: session.photoAAD(id: photoID, sender: p))) ?? Data()
        add(SealedPayload(kind: "photo", photoID: photoID), from: p, at: at(today, 9, 10))
        let nice = UUID().uuidString
        add(SealedPayload(kind: "text", text: "Ne güzel çıkmış! Kahveni de görmüşüm ☕️"), from: m, at: at(today, 9, 12), id: nice)

        let voiceID = UUID().uuidString
        blobs[voiceID] = (try? session.seal(Self.tone(seconds: 3), aad: session.voiceAAD(id: voiceID, sender: p))) ?? Data()
        let wave: [UInt8] = [40, 70, 120, 160, 140, 90, 60, 110, 180, 220, 200, 150, 90, 70, 60, 100, 150, 190, 170, 120,
                             80, 60, 90, 140, 200, 230, 210, 160, 100, 70, 50, 80, 120, 150, 130, 90, 60, 40, 30, 20]
        add(SealedPayload(kind: "voice", voiceID: voiceID, seconds: 14, wave: wave), from: p, at: at(today, 9, 20))
        add(SealedPayload(kind: "heartbeat", bpm: 69), from: m, at: at(today, 9, 25))
        let nervous = UUID().uuidString
        add(SealedPayload(kind: "text", text: "Vize 14:00'te, biraz gerginim"), from: p, at: at(today, 10, 2), id: nervous)
        let reply = UUID().uuidString
        add(SealedPayload(kind: "text", text: "Sen hazırsın. Akşam kutlarız 💚", replyTo: nervous), from: m, at: at(today, 10, 3), id: reply)

        // Reactions: hers on my message, mine on hers.
        add(SealedPayload(kind: "reaction", target: nice, emoji: "❤️"), from: p, at: at(today, 9, 13))
        add(SealedPayload(kind: "reaction", target: olur, emoji: "❤️"), from: m, at: at(yesterday, 21, 44))
        messages.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }

        // She has the chat open, has read everything, and is typing (kept alive for the tour).
        publishPartnerPresence(typing: true, read: reply)
        partnerTypingBeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                let read = self.messages.last?.id
                self.publishPartnerPresence(typing: true, read: read)
            }
        }

        // Her next two weeks.
        func item(_ title: String, _ start: Date, hours: Double = 1.5, allDay: Bool = false) -> AgendaItem {
            AgendaItem(id: UUID().uuidString, title: title, start: start, end: start.addingTimeInterval(hours * 3600),
                       allDay: allDay, source: "Blackboard")
        }
        let tomorrow = today.addingTimeInterval(86_400)
        let agenda = SealedAgenda(items: [
            item("EE204 Vize", calendar.date(bySettingHour: 14, minute: 0, second: 0, of: today) ?? today, hours: 10),
            item("Proje raporu teslimi", calendar.date(bySettingHour: 23, minute: 59, second: 0, of: tomorrow) ?? tomorrow, hours: 0.01),
            item("PHYS102 Quiz", today.addingTimeInterval(3 * 86_400 + 11 * 3600)),
            item("Kulüp toplantısı", today.addingTimeInterval(4 * 86_400 + 18 * 3600)),
        ])
        memberDocs["agenda/\(p)"] = (seal(agenda, aad: session.agendaAAD(of: p)), now)

        // Timetables. Mine: the SIS PDF fixture read by the real importer.
        // A few weeks tracked, one absence, the last two classes left unmarked.
        let mine = TimetableFixture.courses()
        let since = calendar.date(byAdding: .day, value: -21, to: today) ?? today
        let past = Timetable.occurrences(of: mine, from: since, to: now).filter { $0.end <= now }
        var marks: [String: AttendanceMark] = [:]
        for (index, occurrence) in past.dropLast(2).enumerated() {
            marks[occurrence.key] = occurrence.course.code == "EE 303" && index % 3 == 1 ? .absent : .attended
        }
        Timetable.shared.useDemo(courses: mine, since: since, limits: ["EE 303": 4], marks: marks)

        // Hers: in a class right now, another later today.
        let weekday = calendar.component(.weekday, from: now)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let classStart = max(0, minute - 40), classEnd = min(1439, minute + 50)
        let later = min(1380, classEnd + 130)
        let hers = SealedTimetable(courses: [
            Course(code: "PHYS 102", name: "Physics II", sessions: [ClassSession(weekday: weekday, start: classStart, end: classEnd, room: "B201")]),
            Course(code: "MATH 116", name: "Calculus II", sessions: [ClassSession(weekday: weekday, start: later, end: min(1439, later + 50), room: "A210")]),
            Course(code: "EE 204", name: "Circuits II", sessions: [ClassSession(weekday: weekday % 7 + 1, start: 600, end: 770, room: "A414")]),
        ])
        memberDocs["timetable/\(p)"] = (seal(hers, aad: session.timetableAAD(of: p)), now)
    }

    /// A small painted "photo": evening sky, sun, sea.
    private static func photo() -> Data {
        let size = CGSize(width: 900, height: 1200)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.98, green: 0.80, blue: 0.62, alpha: 1).cgColor,
                          UIColor(red: 0.86, green: 0.56, blue: 0.55, alpha: 1).cgColor,
                          UIColor(red: 0.38, green: 0.45, blue: 0.62, alpha: 1).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(red: 1, green: 0.93, blue: 0.78, alpha: 0.9).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 330, y: 520, width: 240, height: 240))
            UIColor(red: 0.24, green: 0.33, blue: 0.48, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 700, width: size.width, height: 500))
        }
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// A soft tone as a WAV file, so the voice bubble really plays.
    private static func tone(seconds: Double) -> Data {
        let rate = 22_050, count = Int(Double(rate) * seconds)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            let envelope = min(1, t * 4) * min(1, (seconds - t) * 4)
            samples[i] = Int16(sin(2 * .pi * 330 * t) * 6000 * envelope)
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(count * 2))
        samples.forEach { append($0) }
        return data
    }
}

private final class DemoToken: ListenerToken {
    private var onCancel: (() -> Void)?
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel?(); onCancel = nil }
}
#endif
