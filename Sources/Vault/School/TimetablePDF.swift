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
        /// The page text had a space or line break right before this character.
        var breakBefore = false
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
        /// Baseline (top-left origin).
        var base: CGFloat { top + unitHeight }
        let unitHeight: CGFloat
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
    ///
    /// Each character is read as a one-character selection, so its text and its
    /// box always belong together (`page.string` indices can drift from the
    /// character-box indices when letters like "İ" are stored decomposed).
    static func glyphs(of page: PDFPage) -> [Glyph] {
        let height = page.bounds(for: .mediaBox).maxY
        var result: [Glyph] = []
        result.reserveCapacity(page.numberOfCharacters)
        var pendingBreak = false
        for index in 0..<page.numberOfCharacters {
            guard let selection = page.selection(for: NSRange(location: index, length: 1)),
                  let character = selection.string, !character.isEmpty else {
                pendingBreak = true
                continue
            }
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingBreak = true
                continue
            }
            var box = selection.bounds(for: page)
            if box.isNull || box.isEmpty { box = page.characterBounds(at: index) }
            if box.isNull || box.isEmpty || box.width <= 0 || box.height <= 0 {
                // A combining mark (the dot of İ) belongs to the previous letter.
                if !result.isEmpty, character.unicodeScalars.allSatisfy({ $0.properties.isGraphemeExtend }) {
                    let last = result.removeLast()
                    result.append(Glyph(text: last.text + character, minX: last.minX, maxX: last.maxX,
                                        top: last.top, bottom: last.bottom, breakBefore: last.breakBefore))
                }
                continue
            }
            result.append(Glyph(text: character, minX: box.minX, maxX: box.maxX,
                                top: height - box.maxY, bottom: height - box.minY, breakBefore: pendingBreak))
            pendingBreak = false
        }
        return result
    }

    // MARK: Parsing (pure; works on any glyph list)

    static func parse(glyphs: [Glyph]) -> [Course]? {
        let heights = glyphs.map(\.height).sorted()
        let unit = heights.isEmpty ? 6 : heights[heights.count / 2]
        let widths = glyphs.map { $0.maxX - $0.minX }.sorted()
        let gap = max((widths.isEmpty ? 4 : widths[widths.count / 2]) * 0.35, 0.8)
        let full = lines(glyphs, unit: unit, gap: gap)
        let days = dayNames.map(fold)
        guard let header = full.first(where: { line in line.words.filter { days.contains(fold($0.text)) }.count >= 5 }) else {
            diagnostics = "no day header in \(full.count) lines; first: \(full.prefix(3).map(\.text))"
            return nil
        }
        var centres: [(day: Int, x: CGFloat)] = []
        for word in header.words {
            if let day = days.firstIndex(of: fold(word.text)), !centres.contains(where: { $0.day == day }) {
                centres.append((day, (word.minX + word.maxX) / 2))
            }
        }
        centres.sort { $0.x < $1.x }
        let stopLine = full.first { $0.base > header.base + unit && (fold($0.text).contains("DERS KODU") || fold($0.text).hasPrefix("DANISMAN")) }
        let stop = stopLine?.base ?? .greatestFiniteMagnitude
        let grid = glyphs.filter { $0.bottom > header.base + unit * 0.5 && $0.bottom < stop - unit * 0.5 }
        let gridLines = lines(grid, unit: unit, gap: gap)

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
        #if DEBUG
        var cellDump: [String] = []
        #endif
        for (index, left) in columns.enumerated() {
            let next = index + 1 < columns.count ? columns[index + 1] : .greatestFiniteMagnitude
            guard let day = centres.first(where: { $0.x >= left - 2 && $0.x < next })?.day else { continue }
            let cell = grid.filter { $0.minX >= left - 2 && $0.minX < next - 2 }
            var code: String?
            var body: [String] = []
            let cellLines = lines(cell, unit: unit, gap: gap)
            #if DEBUG
            cellDump.append("[\(dayNames[day].prefix(3))] " + cellLines.map { "\($0.text)@\(Int($0.base))" }.joined(separator: "|"))
            #endif
            for line in cellLines {
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
            if fold(line.text).contains("DERS KODU") { inList = true; continue }
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
        #if DEBUG
        diagnostics = "glyphs \(glyphs.count) h~\(Int(unit * 10)) cols \(columns.map { Int($0) }) days \(centres.map { Int($0.x) }) "
            + "courses \(courses.count) slots \(sessions.values.map(\.count).reduce(0, +)) stop \(stop < 1e9 ? Int(stop) : -1) "
            + "unit \(Int(unit * 10)) gap \(Int(gap * 10)) stopBase \(Int(stop < 1e9 ? stop : -1)) cells: " + cellDump.joined(separator: " ## ")
            + " list: " + full.filter { $0.base >= stop }.prefix(3).map(\.text).joined(separator: " ¦ ")
        #endif
        return courses.contains(where: { !$0.sessions.isEmpty }) ? courses : nil
    }

    /// What the last parse saw (shown in demo mode when it fails).
    nonisolated(unsafe) static var diagnostics = ""

    /// "PERŞEMBE" and "PERŞEMBE" (decomposed) and "PERSEMBE" compare equal.
    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
            .uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// Groups glyphs into visual lines by baseline. Character boxes may be tight
    /// around the ink, so letters that sit on the baseline set the lines, and
    /// descenders ("y", "ş", ",") and floating marks ("-") join the nearest one.
    private static let descending: Set<String> = ["g", "j", "p", "q", "y", "ç", "ş", "ğ", "Ç", "Ş", "Q", "J",
                                                  ",", ";", "(", ")", "[", "]", "/", "|"]
    private static let floating: Set<String> = ["-", "–", "—", "=", "'", "’", "‘", "\"", "“", "”", "*", "^", "~"]

    private static func lines(_ glyphs: [Glyph], unit: CGFloat, gap: CGFloat) -> [Line] {
        let tolerance = max(unit * 0.35, 1.0)
        var bases: [(base: CGFloat, count: CGFloat)] = []
        for glyph in glyphs.filter({ !descending.contains($0.text) && !floating.contains($0.text) })
            .sorted(by: { $0.bottom < $1.bottom }) {
            if let last = bases.indices.last, glyph.bottom - bases[last].base < tolerance {
                bases[last].base = (bases[last].base * bases[last].count + glyph.bottom) / (bases[last].count + 1)
                bases[last].count += 1
            } else {
                bases.append((glyph.bottom, 1))
            }
        }
        guard !bases.isEmpty else { return [] }
        var members = Array(repeating: [Glyph](), count: bases.count)
        for glyph in glyphs {
            let expected: CGFloat
            if descending.contains(glyph.text) { expected = glyph.bottom - unit * 0.25 }
            else if floating.contains(glyph.text) { expected = glyph.bottom + unit * 0.3 }
            else { expected = glyph.bottom }
            var best = 0
            for index in bases.indices where abs(bases[index].base - expected) < abs(bases[best].base - expected) {
                best = index
            }
            members[best].append(glyph)
        }
        return zip(bases, members).compactMap { base, row in
            guard !row.isEmpty else { return nil }
            let sorted = row.sorted { $0.minX < $1.minX }
            var text = ""
            var words: [Word] = []
            for (index, glyph) in sorted.enumerated() {
                if index > 0, glyph.breakBefore || glyph.minX - sorted[index - 1].maxX > gap {
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
            return Line(text: text, top: base.base - unit, words: words, unitHeight: unit)
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
