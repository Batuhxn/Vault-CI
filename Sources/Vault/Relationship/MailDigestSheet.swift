import SwiftUI

private typealias Room = WatchlinkStyle.Room

@MainActor
struct MailDigestSheet: View {
    let store: WatchlinkStore
    let client: MailDigestClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage private var storedConnected: Bool
    @AppStorage private var savedRules: String
    /// What was last sent to the relay (rules, courses, push token), to send only changes.
    @AppStorage private var sentPrefs: String
    @State private var draft: MailDigest?
    /// When the owner's script last reached the relay; `checked` once the relay answered.
    @State private var seen: Date?
    @State private var checked = false
    @State private var busy = false
    @State private var status: String?
    @State private var confirmShare = false
    @State private var confirmDisconnect = false
    @State private var shared = false
    @State private var expanded: Set<Int> = []
    @State private var rules = ""
    @State private var rulesStatus: String?
    @FocusState private var editingRules: Bool

    init(store: WatchlinkStore, client: MailDigestClient) {
        self.store = store
        self.client = client
        _storedConnected = AppStorage(wrappedValue: false, "wl.mail.connected." + client.ownerID)
        _savedRules = AppStorage(wrappedValue: "", "wl.mail.rules." + client.ownerID)
        _sentPrefs = AppStorage(wrappedValue: "", "wl.mail.prefs." + client.ownerID)
    }

    private var connected: Bool { demo || storedConnected }
    /// The hourly script has not checked in for a while (or the relay has no mailbox):
    /// the summary has quietly stopped and reconnecting usually fixes it.
    private var stale: Bool {
        guard connected, checked, !busy else { return false }
        guard let seen else { return true }
        return Date().timeIntervalSince(seen) > 4 * 60 * 60
    }
    private var canConnect: Bool { !demo && MailDigestClient.connectPageURL != nil }

    var body: some View {
        NavigationStack {
            Form {
                if stale {
                    Section {
                        Label("Özet birkaç saattir güncellenmedi. Yeniden bağlamak genelde düzeltir.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Room.noticeInk)
                        Button("Yeniden bağla") { Task { await connect() } }
                            .disabled(busy || !canConnect)
                    }
                }
                digest
                if connected { rulesSection }
                connection
            }
            .navigationTitle("Mail Özeti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Tamam") { editingRules = false }
                }
            }
            .task {
                rules = savedRules
                await syncPrefs()
                await refresh()
            }
            // Back from Safari after connecting: the first digest may be waiting.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
            }
        }
    }

    // MARK: Digest

    @ViewBuilder
    private var digest: some View {
        if let draft {
            let important = draft.important
            let other = draft.other
            if !important.isEmpty {
                Section {
                    ForEach(Array(important.enumerated()), id: \.offset) { index, item in
                        row(item, key: index)
                    }
                } header: {
                    Label("Önemli", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Room.noticeInk)
                }
            }
            Section {
                if important.isEmpty && other.isEmpty {
                    Text("Önemli bir şey yok.").foregroundStyle(.secondary)
                }
                if !other.isEmpty {
                    DisclosureGroup("Diğer · \(other.count)") {
                        ForEach(Array(other.enumerated()), id: \.offset) { index, item in
                            row(item, key: 1000 + index)
                        }
                    }
                }
                Button(important.isEmpty ? "Sohbette paylaş" : "Önemlileri sohbette paylaş") { confirmShare = true }
                    .disabled(shared || !store.canSend || draft.items.isEmpty)
                    .confirmationDialog("Bunu sohbete gönder?", isPresented: $confirmShare, titleVisibility: .visible) {
                        Button("Paylaş") { share() }
                    }
                if let status { Text(status).foregroundStyle(.secondary) }
                Button("Yenile") { Task { await refresh() } }
                    .disabled(busy)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if draft.atlanan > 0 {
                        Text("\(draft.atlanan) önemsiz mail atlandı (kulüp, anket, bülten gibi).")
                    }
                    Text("Özet sunucuda şifreli bekler ve yalnızca bu telefon açabilir. Sohbette paylaştığın, diğer mesajlar gibi uçtan uca şifrelidir.")
                }
            }
        } else {
            Section {
                if busy {
                    ProgressView()
                } else if status == nil {
                    Text(connected ? "Henüz mail özeti yok. Yeni okul maili gelince burada olur."
                                   : "Henüz mail özeti yok.")
                        .foregroundStyle(.secondary)
                }
                if let status { Text(status).foregroundStyle(.secondary) }
                Button("Yenile") { Task { await refresh() } }
                    .disabled(busy)
            }
        }
    }

    private func row(_ item: MailItem, key: Int) -> some View {
        Button {
            withAnimation(.snappy) {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let kaynak = item.kaynak {
                        Text(kaynak)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.important ? Room.noticeInk : Room.sageDeep)
                    }
                    Spacer(minLength: 0)
                    if let sonTarih = item.sonTarih {
                        Label(sonTarih, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(Room.ink2)
                            .lineLimit(1)
                    }
                }
                Text(item.baslik)
                    .font(.subheadline.weight(item.important ? .semibold : .regular))
                    .foregroundStyle(Room.ink)
                    .multilineTextAlignment(.leading)
                if expanded.contains(key) {
                    if let detay = item.detay {
                        Text(detay).font(.footnote).foregroundStyle(Room.ink2)
                    }
                    if let yapilacak = item.yapilacak {
                        Text("Yapılacak: \(yapilacak)").font(.footnote.weight(.medium)).foregroundStyle(Room.ink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .privacySensitive()
        }
        .buttonStyle(.plain)
    }

    // MARK: Rules

    private var rulesSection: some View {
        Section {
            TextField("Örnek: Yusuf hocanın mailleri her zaman önemli. Kulüp etkinlikleri ve anketler önemsiz. Burs duyuruları önemli.",
                      text: $rules, axis: .vertical)
                .lineLimit(3...8)
                .focused($editingRules)
            Button("Kaydet") { Task { await saveRules() } }
                .disabled(busy || rules == savedRules)
            if let rulesStatus { Text(rulesStatus).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Neyin önemli olduğunu anlat")
        } footer: {
            Text("Ders programındaki derslerin ayrıca kendiliğinden eklenir. Önemli bir mail gelince bildirim alırsın.")
        }
    }

    private func saveRules() async {
        editingRules = false
        let previous = savedRules
        savedRules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        rules = savedRules
        if await syncPrefs() {
            rulesStatus = "Kaydedildi. Bir sonraki özette dikkate alınır."
        } else {
            savedRules = previous
            rulesStatus = "Kaydedilemedi. İnternetini kontrol edip yeniden dene."
        }
    }

    /// Sends rules, courses and this phone's push token when any of them changed.
    @discardableResult
    private func syncPrefs(force: Bool = false) async -> Bool {
        guard storedConnected, !demo else { return true }
        let courses = Timetable.shared.courses
        let push = PushCenter.shared.token
        let signature = ([savedRules, push ?? "-"] + courses.map { $0.code + "/" + $0.name }).joined(separator: "\n")
        guard force || signature != sentPrefs else { return true }
        do {
            try await client.savePrefs(rules: savedRules, courses: courses, push: push)
            sentPrefs = signature
            return true
        } catch {
            return false
        }
    }

    // MARK: Connection

    private var connection: some View {
        Section {
            if connected {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Okul mailin bağlı. Özet her saat yenilenir.")
                        if let seen {
                            Text("Son kontrol " + seen.formatted(.relative(presentation: .named)))
                                .font(.footnote)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
                .foregroundStyle(.secondary)
                Button("Yeniden bağla") { Task { await connect() } }
                    .disabled(busy || !canConnect)
                Button("Bağlantıyı kes", role: .destructive) { confirmDisconnect = true }
                    .disabled(busy)
                    .confirmationDialog("Okul mail bağlantısı kesilsin mi?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                        Button("Bağlantıyı kes", role: .destructive) { Task { await disconnect() } }
                    } message: {
                        Text("Bekleyen özet de silinir.")
                    }
            } else {
                Button { Task { await connect() } } label: {
                    Label("Okul mailimi bağla", systemImage: "envelope.badge")
                }
                .disabled(busy || !canConnect)
            }
        } header: {
            Text("Okul maili")
        } footer: {
            if !connected {
                Text(canConnect
                     ? "Safari'de MEF hesabınla bir kez izin vermen yeterli. Yalnızca okul ve Blackboard mailleri okunur."
                     : "Okul maili bağlantısı yakında.")
            }
        }
    }

    private var demo: Bool {
        #if DEBUG
        DemoMode.isOn
        #else
        false
        #endif
    }

    @MainActor private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        status = nil
        do {
            #if DEBUG
            if demo {
                draft = try MailDigestClient.demoDraft()
                seen = Date().addingTimeInterval(-12 * 60)
                checked = true
                return
            }
            #endif
            let (latest, lastSeen) = try await client.draft()
            if draft?.shareText != latest?.shareText {
                shared = false
                expanded = []
            }
            draft = latest
            seen = lastSeen
            checked = true
        } catch {
            status = "Mail özeti alınamadı. Bağlantını kontrol edip yeniden dene."
        }
    }

    @MainActor private func connect() async {
        guard !busy, canConnect else { return }
        busy = true
        defer { busy = false }
        do {
            let token = try await client.register()
            guard let page = MailDigestClient.connectPage(token: token) else { return }
            draft = nil
            seen = Date()
            shared = false
            status = nil
            storedConnected = true
            // Rules, courses and the push token reach the relay before the first digest.
            await syncPrefs(force: true)
            openURL(page)
        } catch {
            status = "Bağlantı başlatılamadı. İnternetini kontrol edip yeniden dene."
        }
    }

    @MainActor private func disconnect() async {
        guard !busy, !demo else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.disconnect()
            storedConnected = false
            sentPrefs = ""
            draft = nil
            shared = false
            status = "Okul mail bağlantısı kesildi."
        } catch {
            status = "Bağlantı kesilemedi."
        }
    }

    @MainActor private func share() {
        guard let draft, !shared else { return }
        switch store.send(draft.shareText) {
        case .success:
            shared = true
            status = "Sohbete eklendi."
        case .failure:
            status = "Sohbete gönderilemedi."
        }
    }
}
