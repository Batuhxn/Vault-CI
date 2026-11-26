import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// "Bu hafta": the next few things on both calendars, mine first, then the partner's.
struct AgendaCard: View {
    let agenda: SharedAgenda
    let partnerName: String
    @State private var settings = false

    private static let shown = 4

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
                Button { settings = true } label: {
                    Text("Blackboard takvimini paylaş; ikinizin teslim ve sınavları burada yan yana dursun.")
                        .font(.footnote)
                        .foregroundStyle(Room.ink2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if agenda.partnerShares {
                section(title: partnerName.isEmpty ? "O" : partnerName, items: agenda.partners,
                        empty: "Önümüzdeki iki haftada bir şey yok.")
            } else {
                Text("\(partnerName.isEmpty ? "Partnerin" : partnerName) henüz takvim paylaşmadı.")
                    .font(.footnote)
                    .foregroundStyle(Room.ink3)
            }
        }
        .padding(16)
        .background(Room.paper, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Room.ink.opacity(0.06), lineWidth: 1))
        .sheet(isPresented: $settings) { AgendaSettings(agenda: agenda) }
        .task { agenda.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            agenda.refresh()
        }
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
