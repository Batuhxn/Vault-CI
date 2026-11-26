import EventKit
import Foundation
import Observation
import UserNotifications

/// One upcoming event, as shared with the partner (sealed).
struct AgendaItem: Codable, Equatable, Hashable, Identifiable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    /// The calendar it came from ("Blackboard", "MEF", ...).
    var source: String

    /// Exams get a marker and, on the partner's phone, an evening-before reminder.
    var isExam: Bool {
        let lower = title.lowercased(with: Locale(identifier: "tr_TR"))
        return Self.examWords.contains { lower.contains($0) }
    }
    static let examWords = ["sınav", "exam", "midterm", "final", "quiz", "vize", "bütünleme"]
}

/// What a member publishes: their chosen calendars' next two weeks.
struct SealedAgenda: Codable, Equatable {
    var items: [AgendaItem]
}

/// The shared week.
///
/// Each phone reads only the calendars its owner chose (opt-in, nothing by
/// default), takes the next 14 days, seals them and keeps one document in the
/// pair. The partner's phone opens it. Calendars that weren't chosen never
/// leave the phone, and the server sees only sealed bytes. Blackboard reaches
/// this through the iPhone Calendar (a subscribed .ics calendar).
@MainActor @Observable
final class SharedAgenda {
    enum Access: Equatable { case notDetermined, denied, granted }

    struct CalendarChoice: Identifiable, Equatable {
        let id: String
        let title: String
        let subscribed: Bool
        var shared: Bool
        /// Subscribed feeds (Blackboard's .ics) are listed first.
        var suggested: Bool { subscribed || title.localizedCaseInsensitiveContains("blackboard") }
    }

    static let horizon: TimeInterval = 14 * 86_400
    static let maxItems = 40

    private(set) var access: Access = SharedAgenda.currentAccess
    private(set) var calendars: [CalendarChoice] = []
    private(set) var mine: [AgendaItem] = []
    private(set) var partners: [AgendaItem] = []
    /// The partner has published an agenda (possibly empty).
    private(set) var partnerShares = false
    var sharesAnything: Bool { !sharedIDs.isEmpty }

    /// Set by the store: used in reminder text.
    @ObservationIgnored var partnerName: () -> String = { "" }

    @ObservationIgnored private let events = EKEventStore()
    @ObservationIgnored private let backend: any ChatBackend
    @ObservationIgnored private let pairID: String
    @ObservationIgnored private let myID: String
    @ObservationIgnored private let partnerID: String?
    @ObservationIgnored private let session: PairCrypto.Session
    @ObservationIgnored private var listener: (any ListenerToken)?
    @ObservationIgnored private var changes: (any NSObjectProtocol)?
    @ObservationIgnored private var lastPublished: [AgendaItem]?
    @ObservationIgnored private var sharedStorage: Set<String>

    private var sharedIDs: Set<String> {
        get { sharedStorage }
        set {
            sharedStorage = newValue
            UserDefaults.standard.set(Array(newValue), forKey: Self.defaultsKey(pairID))
        }
    }

    init(backend: any ChatBackend, pairID: String, myID: String, partnerID: String?, session: PairCrypto.Session) {
        self.backend = backend
        self.pairID = pairID
        self.myID = myID
        self.partnerID = partnerID
        self.session = session
        sharedStorage = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey(pairID)) ?? [])
    }

    func start() {
        if let partnerID, listener == nil {
            listener = backend.observeMemberDoc(collection: "agenda", pairID: pairID, member: partnerID) { [weak self] sealed, _ in
                Task { @MainActor in self?.receive(sealed) }
            }
        }
        if changes == nil {
            changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: events, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let changes { NotificationCenter.default.removeObserver(changes) }
        changes = nil
    }

    func requestAccess() async {
        _ = try? await events.requestFullAccessToEvents()
        refresh()
    }

    func setShared(_ calendarID: String, _ shared: Bool) {
        if shared { sharedIDs.insert(calendarID) } else { sharedIDs.remove(calendarID) }
        refresh()
    }

    /// Re-reads the chosen calendars and republishes if anything changed.
    func refresh() {
        access = Self.currentAccess
        guard access == .granted else {
            calendars = []
            mine = []
            return
        }
        let all = events.calendars(for: .event)
        let shared = sharedIDs
        calendars = all
            .map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title,
                                  subscribed: $0.type == .subscription, shared: shared.contains($0.calendarIdentifier)) }
            .sorted { ($0.suggested ? 0 : 1, $0.title) < ($1.suggested ? 0 : 1, $1.title) }
        let chosen = all.filter { shared.contains($0.calendarIdentifier) }
        var items: [AgendaItem] = []
        if !chosen.isEmpty {
            let start = Calendar.current.startOfDay(for: Date())
            let predicate = events.predicateForEvents(withStart: start, end: start.addingTimeInterval(Self.horizon), calendars: chosen)
            items = events.events(matching: predicate)
                .sorted { $0.startDate < $1.startDate }
                .prefix(Self.maxItems)
                .map { event in
                    AgendaItem(id: "\(event.calendarItemIdentifier)|\(Int(event.startDate.timeIntervalSince1970))",
                               title: String((event.title ?? "Etkinlik").prefix(120)),
                               start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                               source: String(event.calendar.title.prefix(40)))
                }
        }
        mine = items
        publish(items)
    }

    private func publish(_ items: [AgendaItem]) {
        guard items != lastPublished,
              let data = try? JSONEncoder().encode(SealedAgenda(items: items)),
              let sealed = try? session.seal(data, aad: session.agendaAAD(of: myID)),
              sealed.count <= 32 * 1024 else { return }
        lastPublished = items
        let backend = self.backend, pairID = self.pairID
        Task { try? await backend.setMemberDoc(sealed, collection: "agenda", pairID: pairID) }
    }

    private func receive(_ sealed: Data?) {
        guard let sealed, let partnerID,
              let data = try? session.open(sealed, aad: session.agendaAAD(of: partnerID)),
              let agenda = try? JSONDecoder().decode(SealedAgenda.self, from: data) else { return }
        partnerShares = true
        partners = agenda.items.filter { $0.end > Date() }
        scheduleReminders()
    }

    /// 20:00 the evening before each of the partner's exams, on this phone only.
    private func scheduleReminders() {
        let center = UNUserNotificationCenter.current()
        let name = partnerName()
        let exams = partners.filter(\.isExam)
        Task {
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            let calendar = Calendar.current
            for (index, exam) in exams.enumerated() {
                guard let eve = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: exam.start)),
                      let fire = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: eve), fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = name.isEmpty ? "Yarın sınav günü" : "Yarın \(name) için sınav günü"
                content.body = "\(exam.title) · bir destek mesajı gönder 💌"
                content.sound = .default
                let when = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let request = UNNotificationRequest(identifier: "\(Self.reminderPrefix)\(index)",
                                                    content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
                try? await center.add(request)
            }
        }
    }

    static let reminderPrefix = "wl.agenda."

    private static var currentAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private static func defaultsKey(_ pairID: String) -> String { "agenda.calendars.\(pairID)" }
}
