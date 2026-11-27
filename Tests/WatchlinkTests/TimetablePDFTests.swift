import XCTest
@testable import Vault_App

/// The SIS "Ders Programı" importer, end to end on the fixture page and on
/// hand-made glyphs.
final class TimetablePDFTests: XCTestCase {
    private func course(_ code: String, in courses: [Course]) throws -> Course {
        try XCTUnwrap(courses.first { $0.code == code }, "missing \(code)")
    }

    func testFixturePageReadsEveryCourse() throws {
        let courses = try XCTUnwrap(TimetablePDF.parse(data: TimetableFixture.pdf()), TimetablePDF.diagnostics)
        XCTAssertEqual(Set(courses.map(\.code)),
                       ["AI 233", "EE 301", "EE 303", "OHS 101", "PHYS 103L", "POLS 101", "TURK 114"])

        let pols = try course("POLS 101", in: courses)
        XCTAssertEqual(pols.name, "Introduction to Political Science")
        XCTAssertEqual(pols.sessions, [ClassSession(weekday: 2, start: 600, end: 770, room: "A315")])

        let ai = try course("AI 233", in: courses)
        XCTAssertEqual(ai.name, "Artificial Intelligence and Political Economy")
        XCTAssertEqual(ai.sessions.map(\.weekday), [3, 4])
        XCTAssertEqual(ai.sessions.last?.room, "Online")

        let control = try course("EE 303", in: courses)
        XCTAssertEqual(control.name, "Systems and Control")
        XCTAssertEqual(control.sessions.map(\.timeText), ["13:00–14:50", "10:00–12:50"])

        XCTAssertTrue(try course("EE 301", in: courses).name.hasPrefix("Introduction to Analog and Digital Communication"))
        XCTAssertEqual(try course("PHYS 103L", in: courses).sessions.first?.weekday, 6)
        // Asynchronous: in the course list, never in the grid.
        XCTAssertEqual(try course("TURK 114", in: courses).sessions, [])
    }

    func testWordBreaksSurviveTightSpacing() {
        // "Systems and" with letters touching: only the page text's break separates the words.
        var glyphs: [TimetablePDF.Glyph] = []
        var x: CGFloat = 10
        for (index, word) in ["Systems", "and"].enumerated() {
            for (offset, letter) in word.enumerated() {
                glyphs.append(.init(text: String(letter), minX: x, maxX: x + 3, top: 10, bottom: 16,
                                    breakBefore: index > 0 && offset == 0))
                x += 3
            }
        }
        XCTAssertEqual(TimetablePDF.lineTexts(glyphs), ["Systems and"])
    }

    func testTurkishHeadersAndCodes() {
        XCTAssertEqual(TimetablePDF.fold("PERŞEMBE"), TimetablePDF.fold("PERS\u{0327}EMBE"))
        XCTAssertEqual(TimetablePDF.fold("PAZARTESİ"), "PAZARTESI")
        XCTAssertEqual(TimetablePDF.fold("ÇARŞAMBA"), "CARSAMBA")
        for code in ["EE 303", "PHYS 103L", "AI233", "TURK 114"] { XCTAssertTrue(TimetablePDF.isCode(code), code) }
        for text in ["Maslak", "A414", "10:00 - 12:50", "EE 30"] { XCTAssertFalse(TimetablePDF.isCode(text), text) }
        XCTAssertEqual(TimetablePDF.normalizedCode("AI233"), "AI 233")
        XCTAssertEqual(TimetablePDF.timeRange("10:00 - 12:50")?.0, 600)
        XCTAssertNil(TimetablePDF.timeRange("12:50 - 10:00"))
        XCTAssertEqual(TimetablePDF.room("Maslak A414 4"), "A414")
        XCTAssertEqual(TimetablePDF.room("Maslak Online"), "Online")
    }
}

final class AcademicCalendarTests: XCTestCase {
    private func date(_ text: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }

    func testHolidaysAndHalfDayEves() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        XCTAssertTrue(AcademicCalendar.isClosed(date("2027-04-23"), minute: 9 * 60, calendar: calendar))
        // Eve: morning classes happen, afternoon ones don't.
        XCTAssertFalse(AcademicCalendar.isClosed(date("2027-03-08"), minute: 10 * 60, calendar: calendar))
        XCTAssertTrue(AcademicCalendar.isClosed(date("2027-03-08"), minute: 13 * 60, calendar: calendar))
        XCTAssertFalse(AcademicCalendar.isClosed(date("2027-03-12"), minute: 10 * 60, calendar: calendar))
    }
}
