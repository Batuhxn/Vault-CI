import Foundation
import Observation
import UserNotifications

/// One weekly slot of a course.
struct ClassSession: Codable, Hashable, Identifiable {
    /// Calendar weekday: 1 = Sunday, 2 = Monday … 7 = Saturday.
    var weekday: Int
    /// Minutes from midnight.
    var start: Int
    var end: Int
    var room: String

    var id: String { "\(weekday)-\(start)" }
    /// Monday first: 0 = Monday … 6 = Sunday.
    var dayOrder: Int { (weekday + 5) % 7 }
    var dayName: String { Self.dayNames[dayOrder] }
    var timeText: String { "\(Self.clock(start))–\(Self.clock(end))" }

    static let dayNames = ["Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi", "Pazar"]
    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

struct Course: Codable, Hashable, Identifiable {
    var code: String
    var name: String
    var sessions: [ClassSession]

    var id: String { code }
    /// No weekly slot (asynchronous / online at your own pace): no reminders, no attendance.
    var isAsync: Bool { sessions.isEmpty }
}

/// What a member shares with the partner: only the weekly timetable, never attendance.
struct SealedTimetable: Codable, Equatable {
    var courses: [Course]
}

enum AttendanceMark: String, Codable, CaseIterable, Identifiable {
    case attended, absent, cancelled, exempt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .attended: return "Girdim"
        case .absent: return "Girmedim"
        case .cancelled: return "Ders iptal"
        case .exempt: return "Muafım"
        }
    }
    var symbol: String {
        switch self {
        case .attended: return "checkmark.circle.fill"
        case .absent: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .exempt: return "circle.dashed"
        }
    }
    /// The reminder's buttons.
    var actionID: String { "wl.class.\(rawValue)" }
    var actionTitle: String {
        switch self {
        case .attended: return "Gidiyorum"
        case .absent: return "Gitmiyorum"
        case .cancelled: return "Ders iptal"
        case .exempt: return "Muafım"
        }
    }
}

struct CourseSettings: Codable, Equatable {
    /// Allowed absences (class days). `nil`: only the counter is shown.
    var limit: Int?
    /// The teacher doesn't take attendance: never asked, never counted.
    var noAttendance = false
}

/// One class on one day.
struct ClassOccurrence: Identifiable, Hashable {
    let course: Course
    let session: ClassSession
    let start: Date
    let end: Date

    var id: String { key }
    var key: String { Timetable.key(day: start, code: course.code, start: session.start) }
}

/// The weekly timetable, attendance and the class reminders.
///
/// Imported from the SIS PDF on this phone. The timetable (courses and slots)
/// is sealed and shared with the partner; attendance never leaves the phone.
@MainActor @Observable
final class Timetable {
    static let shared = Timetable()

    private struct Stored: Codable {
        var courses: [Course] = []
        var settings: [String: CourseSettings] = [:]
        var marks: [String: AttendanceMark] = [:]
        /// First day attendance is tracked (the import day).
        var since: Date?
        var reminders = true
    }

    private var stored: Stored
    private(set) var partnerCourses: [Course] = []
    private(set) var partnerShares = false

    var courses: [Course] { stored.courses }
    var hasTimetable: Bool { !stored.courses.isEmpty }

    @ObservationIgnored private var link: (backend: any ChatBackend, pairID: String, myID: String,
                                           partnerID: String?, session: PairCrypto.Session)?
    @ObservationIgnored private var listener: (any ListenerToken)?
    @ObservationIgnored private var lastPublished: [Course]?
    @ObservationIgnored private var ephemeral = false

    static let reminderPrefix = "wl.class."
    static let category = "wl.class"
    static let leadMinutes = 10

    private init() {
        stored = Self.load() ?? Stored()
    }

    // MARK: Pair link

    func attach(backend: any ChatBackend, pairID: String, myID: String, partnerID: String?, session: PairCrypto.Session) {
        detach()
        link = (backend, pairID, myID, partnerID, session)
        if let partnerID {
            listener = backend.observeMemberDoc(collection: "timetable", pairID: pairID, member: partnerID) { [weak self] sealed, _ in
                Task { @MainActor in self?.receive(sealed) }
            }
        }
        lastPublished = nil
        publish()
        rescheduleReminders()
    }

    func detach() {
        listener?.cancel()
        listener = nil
        link = nil
        partnerCourses = []
        partnerShares = false
    }

    private func publish() {
        guard let link, stored.courses != lastPublished,
              let data = try? JSONEncoder().encode(SealedTimetable(courses: stored.courses)),
              let sealed = try? link.session.seal(data, aad: link.session.timetableAAD(of: link.myID)),
              sealed.count <= 32 * 1024 else { return }
        lastPublished = stored.courses
        let backend = link.backend, pairID = link.pairID
        Task { try? await backend.setMemberDoc(sealed, collection: "timetable", pairID: pairID) }
    }

    private func receive(_ sealed: Data?) {
        guard let sealed, let link, let partnerID = link.partnerID,
              let data = try? link.session.open(sealed, aad: link.session.timetableAAD(of: partnerID)),
              let timetable = try? JSONDecoder().decode(SealedTimetable.self, from: data) else { return }
        partnerCourses = timetable.courses
        partnerShares = !timetable.courses.isEmpty
    }

    // MARK: Editing

    /// Replaces the timetable; attendance and per-course settings stay with their course codes.
    func importCourses(_ courses: [Course]) {
        stored.courses = courses
        if stored.since == nil { stored.since = Calendar.current.startOfDay(for: Date()) }
        changed()
    }

    func clear() {
        stored = Stored()
        changed()
    }

    func mark(_ key: String, _ mark: AttendanceMark?) {
        stored.marks[key] = mark
        save()
        if mark != nil {
            // Answered: the reminder for that class (if still pending) is no longer needed.
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderPrefix + key])
        }
    }

    func mark(of occurrence: ClassOccurrence) -> AttendanceMark? { stored.marks[occurrence.key] }

    func settings(for code: String) -> CourseSettings { stored.settings[code] ?? CourseSettings() }

    func setLimit(_ limit: Int?, for code: String) {
        stored.settings[code, default: CourseSettings()].limit = limit
        save()
    }

    func setNoAttendance(_ value: Bool, for code: String) {
        stored.settings[code, default: CourseSettings()].noAttendance = value
        changed()
    }

    var remindersOn: Bool {
        get { stored.reminders }
        set {
            stored.reminders = newValue
            changed()
        }
    }

    private func changed() {
        save()
        publish()
        rescheduleReminders()
    }

    // MARK: Reading

    func course(_ code: String) -> Course? { stored.courses.first { $0.code == code } }

    /// Classes of `courses` between two dates, minus holidays.
    static func occurrences(of courses: [Course], from: Date, to: Date, calendar: Calendar = .current) -> [ClassOccurrence] {
        var result: [ClassOccurrence] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            let weekday = calendar.component(.weekday, from: day)
            for course in courses {
                for session in course.sessions where session.weekday == weekday {
                    guard !AcademicCalendar.isClosed(day, minute: session.start, calendar: calendar),
                          let start = calendar.date(byAdding: .minute, value: session.start, to: day),
                          let end = calendar.date(byAdding: .minute, value: session.end, to: day),
                          end > from, start < to else { continue }
                    result.append(ClassOccurrence(course: course, session: session, start: start, end: end))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Classes of this course that have started since tracking began, newest first.
    func past(_ code: String, now: Date = Date()) -> [ClassOccurrence] {
        guard let course = course(code), let since = stored.since else { return [] }
        return Self.occurrences(of: [course], from: since, to: now)
            .filter { $0.start <= now }
            .reversed()
            .prefix(60)
            .map { $0 }
    }

    func absences(_ code: String) -> Int {
        let needle = "|\(code)|"
        return stored.marks.filter { $0.key.contains(needle) && $0.value == .absent }.count
    }

    /// Finished classes nobody marked (courses that take attendance only).
    func unmarked(_ code: String? = nil, now: Date = Date()) -> [ClassOccurrence] {
        guard let since = stored.since else { return [] }
        let tracked = stored.courses.filter { (code == nil || $0.code == code) && !settings(for: $0.code).noAttendance }
        return Self.occurrences(of: tracked, from: since, to: now)
            .filter { $0.end <= now && stored.marks[$0.key] == nil }
    }

    /// The class in progress and the next one today.
    static func today(_ courses: [Course], at now: Date) -> (current: ClassOccurrence?, next: ClassOccurrence?) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return (nil, nil) }
        let list = occurrences(of: courses, from: start, to: end)
        return (list.first { $0.start <= now && now < $0.end }, list.first { $0.start > now })
    }

    /// The first stretch of an hour or more today when neither of you has class
    /// (from now, between 09:00 and 20:00). `end == nil`: free for the rest of the day.
    func freeTogether(at now: Date) -> (start: Int, end: Int?)? {
        guard hasTimetable, partnerShares else { return nil }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let busy = Self.occurrences(of: stored.courses + partnerCourses, from: start, to: end)
            .map { ($0.session.start, $0.session.end) }
            .sorted { $0.0 < $1.0 }
        guard !busy.isEmpty else { return nil }
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let dayEnd = 20 * 60
        var cursor = max(minute, 9 * 60)
        for (from, to) in busy {
            if from - cursor >= 60 { return (cursor, from) }
            cursor = max(cursor, to)
        }
        return dayEnd - cursor >= 60 ? (cursor, nil) : nil
    }

    static func key(day: Date, code: String, start: Int) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) + "|\(code)|\(start)"
    }

    // MARK: Reminders

    nonisolated static func registerCategory() {
        let actions = AttendanceMark.allCases.map { mark in
            UNNotificationAction(identifier: "wl.class.\(mark.rawValue)", title: mark.actionTitle,
                                 options: mark == .absent ? [.destructive] : [])
        }
        let category = UNNotificationCategory(identifier: "wl.class", actions: actions, intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Called by the app delegate for a reminder button (the app may have been launched for it).
    func handle(actionID: String, key: String) {
        guard let mark = AttendanceMark.allCases.first(where: { $0.actionID == actionID }) else { return }
        self.mark(key, mark)
    }

    /// The next two weeks of classes, ten minutes before each (holidays and
    /// courses without attendance excluded).
    func rescheduleReminders() {
        guard !ephemeral else { return }
        let center = UNUserNotificationCenter.current()
        let courses = stored.reminders ? stored.courses.filter { !settings(for: $0.code).noAttendance } : []
        let marks = stored.marks
        let now = Date()
        let upcoming = Self.occurrences(of: courses, from: now, to: now.addingTimeInterval(14 * 86_400))
            .filter { $0.start.addingTimeInterval(TimeInterval(-Self.leadMinutes * 60)) > now && marks[$0.key] == nil }
            .prefix(40)
        Task {
            let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for occurrence in upcoming {
                let content = UNMutableNotificationContent()
                content.title = "\(occurrence.course.code) · \(ClassSession.clock(occurrence.session.start))"
                let room = occurrence.session.room
                content.body = (room.isEmpty ? "" : "\(room) · ") + "\(Self.leadMinutes) dakika sonra başlıyor"
                content.sound = .default
                content.categoryIdentifier = Self.category
                content.threadIdentifier = Self.category
                content.userInfo = ["key": occurrence.key]
                let fire = occurrence.start.addingTimeInterval(TimeInterval(-Self.leadMinutes * 60))
                let when = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let request = UNNotificationRequest(identifier: Self.reminderPrefix + occurrence.key, content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
                try? await center.add(request)
            }
        }
    }

    // MARK: Storage (this phone only)

    private static var fileURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("watchlink-timetable.json")
    }

    private static func load() -> Stored? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private func save() {
        guard !ephemeral, let url = Self.fileURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    #if DEBUG
    /// Demo mode: an in-memory timetable (never saved, no reminders).
    func useDemo(courses: [Course], since: Date, limits: [String: Int], marks: [String: AttendanceMark]) {
        ephemeral = true
        stored = Stored(courses: courses, settings: limits.mapValues { CourseSettings(limit: $0) },
                        marks: marks, since: since, reminders: true)
    }
    #endif
}
