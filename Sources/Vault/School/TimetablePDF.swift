import Foundation
import PDFKit

/// Reads the "Ders Programı" PDF that MEF SIS exports (top-left PDF button).
///
/// Everything happens on the phone and nothing is kept but the timetable: the
/// personal block at the top of the page (name, national ID number) is above
/// the day header and is never read into the result.
///
/// The page is a table: a header row of day names, then one cell per day with
/// stacked blocks ("EE 303 / Systems and Control / Maslak A414 4 / 10:00 - 12:50"),
/// then a course list ("DERS KODU ... DERS ADI ... SECTION ..."). Cells start at
/// the same left edge as their first course code, and each header is centred in
/// its cell, so a column belongs to the first day whose header centre lies at or
/// after the column's left edge.
enum TimetablePDF {
    struct Glyph {
        let text: String
        let minX: CGFloat
        let maxX: CGFloat
        let top: CGFloat
        let bottom: CGFloat
        var height: CGFloat { bottom - top }
        var midY: CGFloat { (top + bottom) / 2 }
    }

    private struct Word {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
    }

    private struct Line {
        let text: String
        let top: CGFloat
        let words: [Word]
    }

    static let dayNames = ["PAZARTESİ", "SALI", "ÇARŞAMBA", "PERŞEMBE", "CUMA", "CUMARTESİ", "PAZAR"]
    /// Calendar weekday (1 = Sunday) for each header above.
    static let weekdays = [2, 3, 4, 5, 6, 7, 1]

    static func parse(data: Data) -> [Course]? {
        guard let document = PDFDocument(data: data) else { return nil }
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), let courses = parse(glyphs: glyphs(of: page)) { return courses }
        }
        return nil
    }

    /// Characters with their boxes, top-left origin.
    static func glyphs(of page: PDFPage) -> [Glyph] {
        guard let string = page.string else { return [] }
        let text = string as NSString
        let height = page.bounds(for: .mediaBox).maxY
        var result: [Glyph] = []
        result.reserveCapacity(text.length)
        for index in 0..<text.length {
            let character = text.substring(with: NSRange(location: index, length: 1))
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let box = page.characterBounds(at: index)
            if box.isNull || box.isEmpty || box.width <= 0 || box.height <= 0 { continue }
            result.append(Glyph(text: character, minX: box.minX, maxX: box.maxX,
                                top: height - box.maxY, bottom: height - box.minY))
        }
        return result
    }

    // MARK: Parsing (pure; works on any glyph list)

    static func parse(glyphs: [Glyph]) -> [Course]? {
        let full = lines(glyphs)
        guard let header = full.first(where: { line in line.words.filter { dayNames.contains($0.text) }.count >= 5 }) else {
            return nil
        }
        var centres: [(day: Int, x: CGFloat)] = []
        for word in header.words {
            if let day = dayNames.firstIndex(of: word.text), !centres.contains(where: { $0.day == day }) {
                centres.append((day, (word.minX + word.maxX) / 2))
            }
        }
        centres.sort { $0.x < $1.x }
        let headerBottom = header.top + 1
        let stop = full.first { $0.top > headerBottom && ($0.text.contains("DERS KODU") || $0.text.hasPrefix("DANIŞMAN")) }?.top
            ?? .greatestFiniteMagnitude

        let grid = glyphs.filter { $0.top > headerBottom + 2 && $0.bottom < stop - 1 }
        let gridLines = lines(grid)

        // Column left edges: where course codes start.
        var lefts: [CGFloat] = []
        for line in gridLines {
            for (index, word) in line.words.enumerated() {
                let joined = index + 1 < line.words.count ? word.text + " " + line.words[index + 1].text : word.text
                if isCode(word.text) || (isCode(joined) && word.text.allSatisfy(\.isLetter)) {
                    lefts.append(word.minX)
                }
            }
        }
        var columns: [CGFloat] = []
        for x in lefts.sorted() where columns.last.map({ x - $0 > 8 }) ?? true {
            columns.append(x)
        }

        var sessions: [String: [ClassSession]] = [:]
        for (index, left) in columns.enumerated() {
            let next = index + 1 < columns.count ? columns[index + 1] : .greatestFiniteMagnitude
            guard let day = centres.first(where: { $0.x >= left - 2 && $0.x < next })?.day else { continue }
            let cell = grid.filter { $0.minX >= left - 2 && $0.minX < next - 2 }
            var code: String?
            var body: [String] = []
            for line in lines(cell) {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                if isCode(text) {
                    code = normalizedCode(text)
                    body = []
                } else if let current = code {
                    if let (start, end) = timeRange(text) {
                        sessions[current, default: []].append(
                            ClassSession(weekday: weekdays[day], start: start, end: end, room: room(body.last ?? "")))
                        code = nil
                    } else {
                        body.append(text)
                    }
                }
            }
        }

        // Course names (and courses without a slot: asynchronous ones).
        var names: [(code: String, name: String)] = []
        var inList = false
        for line in full {
            if line.text.contains("DERS KODU") { inList = true; continue }
            guard inList, let row = courseRow(line.text) else { continue }
            if !names.contains(where: { $0.code == row.code }) { names.append(row) }
        }

        var courses: [Course] = names.map { entry in
            Course(code: entry.code, name: entry.name,
                   sessions: (sessions[entry.code] ?? []).sorted { ($0.dayOrder, $0.start) < ($1.dayOrder, $1.start) })
        }
        for (code, list) in sessions where !courses.contains(where: { $0.code == code }) {
            courses.append(Course(code: code, name: "", sessions: list.sorted { ($0.dayOrder, $0.start) < ($1.dayOrder, $1.start) }))
        }
        return courses.contains(where: { !$0.sessions.isEmpty }) ? courses : nil
    }

    private static func lines(_ glyphs: [Glyph]) -> [Line] {
        var rows: [(mid: CGFloat, glyphs: [Glyph])] = []
        for glyph in glyphs.sorted(by: { $0.midY < $1.midY }) {
            if let last = rows.indices.last, abs(rows[last].mid - glyph.midY) < glyph.height * 0.5 {
                rows[last].glyphs.append(glyph)
            } else {
                rows.append((glyph.midY, [glyph]))
            }
        }
        return rows.map { row in
            let sorted = row.glyphs.sorted { $0.minX < $1.minX }
            var text = ""
            var words: [Word] = []
            for (index, glyph) in sorted.enumerated() {
                if index > 0, glyph.minX - sorted[index - 1].maxX > glyph.height * 0.2 {
                    text += " "
                    words.append(Word(text: glyph.text, minX: glyph.minX, maxX: glyph.maxX))
                } else if words.isEmpty {
                    words.append(Word(text: glyph.text, minX: glyph.minX, maxX: glyph.maxX))
                } else {
                    words[words.count - 1].text += glyph.text
                    words[words.count - 1].maxX = glyph.maxX
                }
                text += glyph.text
            }
            return Line(text: text, top: sorted.map(\.top).min() ?? 0, words: words)
        }
    }

    // "EE 303", "PHYS 103L", "AI233"
    static func isCode(_ text: String) -> Bool {
        text.range(of: #"^[A-ZÇĞİÖŞÜ]{2,5} ?[0-9]{3}[A-Z]?$"#, options: .regularExpression) != nil
    }

    static func normalizedCode(_ text: String) -> String {
        guard let digit = text.firstIndex(where: \.isNumber) else { return text }
        let letters = text[..<digit].trimmingCharacters(in: .whitespaces)
        return "\(letters) \(text[digit...])"
    }

    /// "10:00 - 12:50" → minutes from midnight.
    static func timeRange(_ text: String) -> (Int, Int)? {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "-–")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let start = minutes(parts[0]), let end = minutes(parts[1]), end > start else { return nil }
        return (start, end)
    }

    private static func minutes(_ text: String) -> Int? {
        let pieces = text.split(separator: ":")
        guard pieces.count == 2, let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    /// "Maslak A414 4" → "A414", "Maslak Online" → "Online".
    static func room(_ text: String) -> String {
        var parts = text.split(separator: " ").map(String.init)
        if parts.count >= 2, parts[0].allSatisfy(\.isLetter) { parts.removeFirst() }
        if parts.count >= 2, parts.last?.allSatisfy(\.isNumber) == true { parts.removeLast() }
        return parts.joined(separator: " ")
    }

    /// "EE 303  Systems and Control  1  YUSUF AYDIN  6.0" → ("EE 303", "Systems and Control").
    static func courseRow(_ text: String) -> (code: String, name: String)? {
        let pattern = #"^([A-ZÇĞİÖŞÜ]{2,5} ?[0-9]{3}[A-Z]?)\s+(.+?)\s+[0-9]{1,3}\s+.+\s+[0-9]+(?:[.,][0-9]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let code = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else {
            return nil
        }
        return (normalizedCode(String(text[code])), String(text[name]))
    }
}
