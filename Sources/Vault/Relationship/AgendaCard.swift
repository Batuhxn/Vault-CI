import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// "Bu hafta": the next few things on both calendars, mine first, then the partner's.
struct AgendaCard: View {
    let agenda: SharedAgenda
    let partnerName: String
    @State private var settings = false
    @State private var week = false

    /// Home stays calm: the next two each; the whole week is one tap away.
    private static let shown = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bu hafta")
                    .font(.headline)
                    .foregroundStyle(Room.ink)
                Spacer()
                Button { settings = true } label: {
                    Image(systemName: "calendar.badge.plus")
                        .font(.body)
                        .foregroundStyle(Room.sageDeep)
                        .frame(width: 36, height: 36)
                        .background(Room.control, in: Circle())
                }
                .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
                .accessibilityLabel("Takvim paylaşımı")
            }

            if agenda.access == .granted && agenda.sharesAnything {
                section(title: "Sen", items: agenda.mine, empty: "Önümüzdeki iki haftada bir şey yok.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Blackboard takvimini paylaş; ikinizin teslim ve sınavları burada yan yana dursun.")
                        .font(.footnote)
                        .foregroundStyle(Room.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Button { settings = true } label: {
                        Text("Takvimini paylaş")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Room.sageDeep)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Room.mist, in: Capsule())
                    }
                    .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
                }
            }

            if agenda.partnerShares {
                section(title: partnerName.isEmpty ? "O" : partnerName, items: agenda.partners,
                        empty: "Önümüzdeki iki haftada bir şey yok.")
            } else {
                Text("\(partnerName.isEmpty ? "Partnerin" : partnerName) henüz takvim paylaşmadı.")
                    .font(.footnote)
                    .foregroundStyle(Room.ink3)
            }

            if hiddenCount > 0 {
                Button { week = true } label: {
                    HStack(spacing: 4) {
                        Text("Tüm hafta")
                        Text("+\(hiddenCount)").foregroundStyle(Room.ink3)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Room.sageDeep)
                    .frame(minHeight: 32)
                }
                .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            }
        }
        .padding(16)
        .background(Room.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Room.ink.opacity(0.06), lineWidth: 1))
        .sheet(isPresented: $settings) { AgendaSettings(agenda: agenda) }
        .sheet(isPresented: $week) { AgendaWeek(agenda: agenda, partnerName: partnerName) }
        .task { agenda.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            agenda.refresh()
        }
    }

    /// How many upcoming items the card leaves out (shown in the week sheet).
    private var hiddenCount: Int {
        let now = Date()
        let mine = agenda.access == .granted && agenda.sharesAnything ? agenda.mine.filter { $0.end > now }.count : 0
        let theirs = agenda.partners.filter { $0.end > now }.count
        return max(0, mine - Self.shown) + max(0, theirs - Self.shown)
    }

    @ViewBuilder
    private func section(title: String, items: [AgendaItem], empty: String) -> some View {
        let upcoming = items.filter { $0.end > Date() }.prefix(Self.shown)
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Room.sageDeep)
            if upcoming.isEmpty {
                Text(empty).font(.footnote).foregroundStyle(Room.ink3)
            }
            ForEach(Array(upcoming)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.when(item))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Room.ink3)
                        .frame(width: 78, alignment: .leading)
                    Text(item.title)
                        .font(.subheadline)
                        .foregroundStyle(Room.ink)
                        .lineLimit(1)
                    if item.isExam {
                        Image(systemName: "pencil.and.list.clipboard")
                            .font(.caption)
                            .foregroundStyle(Room.sage)
                            .accessibilityLabel("Sınav")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "Bugün 10:00", "Yarın", "Çar 3 14:00"
    static func when(_ item: AgendaItem, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = item.allDay ? "" : " " + item.start.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(item.start, inSameDayAs: now) || (item.start < now && item.end > now) { return "Bugün" + time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(item.start, inSameDayAs: tomorrow) {
            return "Yarın" + time
        }
        return item.start.formatted(.dateTime.weekday(.abbreviated).day().locale(Locale(identifier: "tr_TR"))) + time
    }
}

/// The whole two weeks, day by day, both of you together.
private struct AgendaWeek: View {
    let agenda: SharedAgenda
    let partnerName: String
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let item: AgendaItem
        let mine: Bool
        var id: String { (mine ? "m|" : "p|") + item.id }
    }

    var body: some View {
        let now = Date()
        let calendar = Calendar.current
        let entries = (agenda.mine.map { Entry(item: $0, mine: true) } + agenda.partners.map { Entry(item: $0, mine: false) })
            .filter { $0.item.end > now }
            .sorted { $0.item.start < $1.item.start }
        let days = Dictionary(grouping: entries) { calendar.startOfDay(for: max($0.item.start, calendar.startOfDay(for: now))) }
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("Önümüzdeki iki haftada bir şey yok.").foregroundStyle(Room.ink3)
                }
                ForEach(days.keys.sorted(), id: \.self) { day in
                    Section(Self.dayTitle(day, now: now, calendar: calendar)) {
                        ForEach(days[day] ?? []) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.item.allDay ? "Tüm gün" : entry.item.start.formatted(date: .omitted, time: .shortened))
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(Room.ink3)
                                    .frame(minWidth: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.item.title).foregroundStyle(Room.ink)
                                    Text(entry.mine ? "Sen" : (partnerName.isEmpty ? "O" : partnerName))
                                        .font(.caption)
                                        .foregroundStyle(entry.mine ? Room.ink3 : Room.sageDeep)
                                }
                                Spacer(minLength: 0)
                                if entry.item.isExam {
                                    Image(systemName: "pencil.and.list.clipboard")
                                        .foregroundStyle(Room.sage)
                                        .accessibilityLabel("Sınav")
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .navigationTitle("Bu hafta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Bugün" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(day, inSameDayAs: tomorrow) { return "Yarın" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "tr_TR")))
    }
}

/// Which calendars leave this phone, and how to add Blackboard.
private struct AgendaSettings: View {
    let agenda: SharedAgenda
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Seçtiğin takvimlerin önümüzdeki iki haftası şifrelenip sadece partnerine gider. Seçmediğin takvimler telefonundan çıkmaz.")
                        .font(.footnote)
                        .foregroundStyle(Room.ink2)
                }
                switch agenda.access {
                case .notDetermined:
                    Section {
                        Button("Takvime erişime izin ver") { Task { await agenda.requestAccess() } }
                    }
                case .denied:
                    Section {
                        Text("Takvim izni kapalı. Ayarlar → Watchlink → Takvimler'den açabilirsin.")
                            .font(.footnote)
                        Button("Ayarları aç") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                case .granted:
                    Section("Paylaşılacak takvimler") {
                        if agenda.calendars.isEmpty {
                            Text("Bu telefonda takvim yok.").foregroundStyle(Room.ink3)
                        }
                        ForEach(agenda.calendars) { calendar in
                            Toggle(isOn: Binding(get: { calendar.shared }, set: { agenda.setShared(calendar.id, $0) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(calendar.title)
                                    if calendar.suggested {
                                        Text("Abone olunan takvim · önerilen")
                                            .font(.caption)
                                            .foregroundStyle(Room.sage)
                                    }
                                }
                            }
                            .tint(Room.sage)
                        }
                    }
                }
                Section("Blackboard'u eklemek için") {
                    Text("1. Blackboard → Takvim → Ayarlar (dişli) → Takvimi paylaş → bağlantıyı kopyala.")
                    Text("2. iPhone Ayarlar → Takvim → Hesaplar → Hesap Ekle → Diğer → Abone Olunan Takvim Ekle → bağlantıyı yapıştır.")
                    Text("3. Buraya dönüp yeni takvimi aç.")
                }
                .font(.footnote)
                .foregroundStyle(Room.ink2)
            }
            .navigationTitle("Takvim paylaşımı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
        }
    }
}
