import SwiftUI
import UniformTypeIdentifiers

private typealias Room = WatchlinkStyle.Room

/// Home: one quiet card, only when there is a timetable and something to say
/// today: the class now or next, the partner in class, a free hour together,
/// classes left unmarked.
struct TodayStrip: View {
    let timetable: Timetable
    let partnerName: String
    let now: Date
    @State private var open = false

    var body: some View {
        let rows = self.rows
        if !rows.isEmpty {
            Button { open = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.text) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: row.symbol)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(row.warning ? Room.noticeInk : Room.sageDeep)
                                .frame(width: 18)
                            Text(row.text)
                                .font(.subheadline)
                                .foregroundStyle(row.warning ? Room.noticeInk : Room.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Room.paper, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Room.ink.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            .accessibilityHint("Ders programını açar")
            .sheet(isPresented: $open) { TimetableSheet(timetable: timetable, partnerName: partnerName) }
        }
    }

    private struct Row {
        let symbol: String
        let text: String
        var warning = false
    }

    private var rows: [Row] {
        var rows: [Row] = []
        let name = partnerName.isEmpty ? "Partnerin" : partnerName
        if timetable.hasTimetable {
            if let closure = AcademicCalendar.closure(on: now) {
                let text = closure.from > 0
                    ? "Bugün \(ClassSession.clock(closure.from)) sonrası ders yok · \(closure.label)"
                    : "Bugün ders yok · \(closure.label)"
                rows.append(Row(symbol: "sun.max", text: text))
            }
            let today = Timetable.today(timetable.courses, at: now)
            if let current = today.current {
                rows.append(Row(symbol: "book.closed", text: "Şimdi \(current.course.code)\(Self.room(current)) · bitiş \(ClassSession.clock(current.session.end))"))
            } else if let next = today.next {
                rows.append(Row(symbol: "clock", text: "Sıradaki \(next.course.code) · \(ClassSession.clock(next.session.start))\(Self.room(next))"))
            }
        }
        if timetable.partnerShares, let current = Timetable.today(timetable.partnerCourses, at: now).current {
            rows.append(Row(symbol: "person", text: "\(name) derste · bitiş \(ClassSession.clock(current.session.end))"))
        }
        if let free = timetable.freeTogether(at: now) {
            let text = free.end.map { "İkiniz de boşsunuz · \(ClassSession.clock(free.start))–\(ClassSession.clock($0))" }
                ?? "İkiniz de boşsunuz · \(ClassSession.clock(free.start)) sonrası"
            rows.append(Row(symbol: "cup.and.saucer", text: text))
        }
        let unmarked = timetable.unmarked(now: now).count
        if unmarked > 0 {
            rows.append(Row(symbol: "exclamationmark.circle", text: "\(unmarked) ders işaretsiz", warning: true))
        }
        return rows
    }

    private static func room(_ occurrence: ClassOccurrence) -> String {
        occurrence.session.room.isEmpty ? "" : " · \(occurrence.session.room)"
    }
}

/// The timetable: import from the SIS PDF, courses with attendance, reminders.
struct TimetableSheet: View {
    let timetable: Timetable
    let partnerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var pending: [Course]?
    @State private var problem: String?
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                if let pending {
                    preview(pending)
                } else if !timetable.hasTimetable {
                    empty
                } else {
                    courses
                }
            }
            .navigationTitle("Ders Programı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                read(result)
            }
        }
    }

    // MARK: Empty

    private var empty: some View {
        Section {
            Text("MEF SIS'te **Ders Programı** sayfasını aç, sol üstteki **PDF** düğmesiyle indir, sonra buradan seç.")
                .font(.subheadline)
                .foregroundStyle(Room.ink2)
            Button { importing = true } label: {
                Label("PDF'ten içe aktar", systemImage: "doc.badge.plus")
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Room.noticeInk)
            }
            #if DEBUG
            if DemoMode.isOn {
                Text("parse: \(TimetablePDF.diagnostics)").font(.caption.monospaced()).foregroundStyle(Room.ink3)
            }
            #endif
        } footer: {
            Text("PDF bu telefonda okunur; adın ve kimlik numaran okunmaz, dosya hiçbir yere gönderilmez.")
        }
    }

    // MARK: Preview

    @ViewBuilder
    private func preview(_ courses: [Course]) -> some View {
        Section {
            Text("Doğru görünüyorsa kaydet.")
                .font(.subheadline)
                .foregroundStyle(Room.ink2)
        }
        WeekList(courses: courses)
        Section {
            Button("Kaydet") {
                timetable.importCourses(courses)
                pending = nil
            }
            .fontWeight(.semibold)
            Button("Vazgeç", role: .cancel) { pending = nil }
        }
    }

    // MARK: Courses

    @ViewBuilder
    private var courses: some View {
        let unmarked = timetable.unmarked().count
        if unmarked > 0 {
            Section {
                Label("\(unmarked) ders işaretsiz", systemImage: "exclamationmark.circle")
                    .foregroundStyle(Room.noticeInk)
            } footer: {
                Text("Derse dokunup geçmiş dersleri işaretleyebilirsin.")
            }
        }
        Section("Dersler") {
            ForEach(timetable.courses) { course in
                NavigationLink {
                    CourseDetail(timetable: timetable, code: course.code)
                } label: {
                    CourseRow(timetable: timetable, course: course)
                }
            }
        }
        WeekList(courses: timetable.courses)
        Section {
            Toggle("Dersten 10 dk önce sor", isOn: Binding(get: { timetable.remindersOn }, set: { timetable.remindersOn = $0 }))
        } footer: {
            Text("Bildirimde Gidiyorum, Gitmiyorum, Ders iptal ve Muafım seçenekleri olur. Cevaplamadığın dersler işaretsiz kalır.")
        }
        Section {
            Button("Yeni PDF içe aktar") { importing = true }
            Button("Programı sil", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Ders programı ve yoklama kayıtları silinsin mi?", isPresented: $confirmDelete,
                                    titleVisibility: .visible) {
                    Button("Sil", role: .destructive) { timetable.clear() }
                }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(Room.noticeInk)
            }
        } footer: {
            Text("Programın \(partnerName.isEmpty ? "partnerinle" : "\(partnerName) ile") şifreli paylaşılır; yoklaman yalnızca bu telefonda kalır.")
        }
    }

    private func read(_ result: Result<URL, Error>) {
        problem = nil
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let courses = TimetablePDF.parse(data: data) else {
            problem = "Bu PDF'te ders programı bulunamadı. SIS'teki Ders Programı sayfasının PDF'ini seç."
            return
        }
        pending = courses
    }
}

/// Monday to Sunday, only days with classes; asynchronous courses at the end.
struct WeekList: View {
    let courses: [Course]

    private struct Slot {
        let course: Course
        let session: ClassSession
        var id: String { "\(course.code)|\(session.id)" }
    }

    var body: some View {
        ForEach(0..<7, id: \.self) { day in
            let slots = courses
                .flatMap { course in course.sessions.filter { $0.dayOrder == day }.map { Slot(course: course, session: $0) } }
                .sorted { $0.session.start < $1.session.start }
            if !slots.isEmpty {
                Section(ClassSession.dayNames[day]) {
                    ForEach(slots, id: \.id) { slot in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(slot.session.timeText)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Room.ink3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.course.code).font(.subheadline.weight(.semibold))
                                if !slot.session.room.isEmpty {
                                    Text(slot.session.room).font(.footnote).foregroundStyle(Room.ink2)
                                }
                            }
                        }
                    }
                }
            }
        }
        let asyncCourses = courses.filter(\.isAsync)
        if !asyncCourses.isEmpty {
            Section("Asenkron") {
                ForEach(asyncCourses) { course in
                    Text(course.code).font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct CourseRow: View {
    let timetable: Timetable
    let course: Course

    var body: some View {
        let settings = timetable.settings(for: course.code)
        let absent = timetable.absences(course.code)
        let unmarked = course.isAsync || settings.noAttendance ? 0 : timetable.unmarked(course.code).count
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(course.code).font(.subheadline.weight(.semibold))
                Spacer()
                Text(status(settings: settings, absent: absent))
                    .font(.footnote)
                    .foregroundStyle(warning(settings: settings, absent: absent) ? Room.noticeInk : Room.ink3)
            }
            if !course.name.isEmpty {
                Text(course.name).font(.footnote).foregroundStyle(Room.ink2).lineLimit(1)
            }
            if unmarked > 0 {
                Text("\(unmarked) işaretsiz").font(.caption.weight(.semibold)).foregroundStyle(Room.noticeInk)
            }
        }
    }

    private func status(settings: CourseSettings, absent: Int) -> String {
        if course.isAsync { return "Asenkron" }
        if settings.noAttendance { return "Yoklama yok" }
        if let limit = settings.limit {
            let left = limit - absent
            return left > 0 ? "\(left) hak kaldı" : (left == 0 ? "Hak kalmadı" : "Sınır aşıldı")
        }
        return absent == 0 ? "Devamsızlık yok" : "\(absent) devamsızlık"
    }

    private func warning(settings: CourseSettings, absent: Int) -> Bool {
        guard let limit = settings.limit, !settings.noAttendance else { return false }
        return limit - absent <= 1
    }
}

/// One course: its slots, attendance (with an optional limit) and past classes to mark.
struct CourseDetail: View {
    let timetable: Timetable
    let code: String

    var body: some View {
        Form {
            if let course = timetable.course(code) {
                let settings = timetable.settings(for: code)
                Section {
                    if course.isAsync {
                        Text("Asenkron ders · hatırlatma ve yoklama yok").foregroundStyle(Room.ink2)
                    }
                    ForEach(course.sessions) { session in
                        HStack {
                            Text(session.dayName)
                            Spacer()
                            Text(session.room.isEmpty ? session.timeText : "\(session.timeText) · \(session.room)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Room.ink2)
                        }
                    }
                } header: {
                    if !course.name.isEmpty { Text(course.name) }
                }
                if !course.isAsync {
                    attendance(settings)
                    if !settings.noAttendance { history }
                }
            }
        }
        .navigationTitle(code)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func attendance(_ settings: CourseSettings) -> some View {
        let absent = timetable.absences(code)
        Section {
            if !settings.noAttendance {
                LabeledContent("Devamsızlık", value: "\(absent) ders günü")
                Toggle("Sınır belirle", isOn: Binding(get: { settings.limit != nil },
                                                      set: { timetable.setLimit($0 ? 4 : nil, for: code) }))
                if let limit = settings.limit {
                    Stepper("Sınır: \(limit) ders günü", value: Binding(get: { limit }, set: { timetable.setLimit($0, for: code) }),
                            in: 1...40)
                    Text(limit - absent > 0 ? "\(limit - absent) hakkın kaldı" : "Hakkın kalmadı")
                        .foregroundStyle(limit - absent <= 1 ? Room.noticeInk : Room.ink2)
                }
            }
            Toggle("Bu derste yoklama yok", isOn: Binding(get: { settings.noAttendance },
                                                           set: { timetable.setNoAttendance($0, for: code) }))
        } header: {
            Text("Yoklama")
        } footer: {
            Text(settings.noAttendance ? "Bu ders için hatırlatma gelmez, devamsızlık sayılmaz."
                                       : "Sınır isteğe bağlı; derse göre değişiyorsa buradan ayarla.")
        }
    }

    @ViewBuilder
    private var history: some View {
        let past = timetable.past(code)
        if !past.isEmpty {
            Section("Geçmiş dersler") {
                ForEach(past) { occurrence in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(occurrence.start.formatted(.dateTime.day().month(.wide).weekday(.wide)))
                                .font(.subheadline)
                            Text(occurrence.session.timeText)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Room.ink3)
                        }
                        Spacer()
                        Menu {
                            ForEach(AttendanceMark.allCases) { mark in
                                Button { timetable.mark(occurrence.key, mark) } label: {
                                    Label(mark.title, systemImage: mark.symbol)
                                }
                            }
                            if timetable.mark(of: occurrence) != nil {
                                Button("İşareti kaldır", role: .destructive) { timetable.mark(occurrence.key, nil) }
                            }
                        } label: {
                            MarkLabel(mark: timetable.mark(of: occurrence))
                        }
                    }
                }
            }
        }
    }
}

private struct MarkLabel: View {
    let mark: AttendanceMark?

    var body: some View {
        if let mark {
            Label(mark.title, systemImage: mark.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(mark == .absent ? Room.blocking : Room.sageDeep)
        } else {
            Label("İşaretsiz", systemImage: "circle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Room.noticeInk)
        }
    }
}
