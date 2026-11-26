import Foundation

/// Days without classes. Official holidays in Türkiye for the 2026–27 year
/// (religious dates as announced by Diyanet). MEF's own term dates and exam
/// weeks go here when the university publishes them; until then a cancelled
/// class is one tap ("Ders iptal") in the reminder.
enum AcademicCalendar {
    struct Closure {
        let label: String
        /// Minutes from midnight when the closure starts (half-day eves start at 13:00).
        let from: Int
    }

    private static let days: [String: Closure] = {
        var all: [String: Closure] = [:]
        func add(_ dates: [String], _ label: String, from: Int = 0) {
            for date in dates { all[date] = Closure(label: label, from: from) }
        }
        add(["2026-10-28"], "Cumhuriyet Bayramı arifesi", from: 13 * 60)
        add(["2026-10-29"], "Cumhuriyet Bayramı")
        add(["2027-01-01"], "Yılbaşı")
        add(["2027-03-08"], "Ramazan Bayramı arifesi", from: 13 * 60)
        add(["2027-03-09", "2027-03-10", "2027-03-11"], "Ramazan Bayramı")
        add(["2027-04-23"], "Ulusal Egemenlik ve Çocuk Bayramı")
        add(["2027-05-01"], "Emek ve Dayanışma Günü")
        add(["2027-05-15"], "Kurban Bayramı arifesi", from: 13 * 60)
        add(["2027-05-16", "2027-05-17", "2027-05-18", "2027-05-19"], "Kurban Bayramı")
        add(["2027-07-15"], "Demokrasi ve Millî Birlik Günü")
        add(["2027-08-30"], "Zafer Bayramı")
        add(["2027-10-28"], "Cumhuriyet Bayramı arifesi", from: 13 * 60)
        add(["2027-10-29"], "Cumhuriyet Bayramı")
        return all
    }()

    static func closure(on date: Date, calendar: Calendar = .current) -> Closure? {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return days[String(format: "%04d-%02d-%02d", year, month, day)]
    }

    /// A class starting at `minute` on `date` doesn't happen.
    static func isClosed(_ date: Date, minute: Int, calendar: Calendar = .current) -> Bool {
        guard let closure = closure(on: date, calendar: calendar) else { return false }
        return minute >= closure.from
    }
}
