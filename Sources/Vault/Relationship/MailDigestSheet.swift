import SwiftUI

@MainActor
struct MailDigestSheet: View {
    let store: WatchlinkStore
    let client: MailDigestClient

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage private var storedConnected: Bool
    @State private var draft: MailDigest?
    @State private var busy = false
    @State private var status: String?
    @State private var confirmShare = false
    @State private var confirmDisconnect = false
    @State private var shared = false

    init(store: WatchlinkStore, client: MailDigestClient) {
        self.store = store
        self.client = client
        _storedConnected = AppStorage(wrappedValue: false, "wl.mail.connected." + client.ownerID)
    }

    private var connected: Bool { demo || storedConnected }
    private var canConnect: Bool { !demo && MailDigestClient.connectPageURL != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let draft {
                        Text(draft.shareText)
                            .textSelection(.enabled)
                            .privacySensitive()
                        Button("Sohbette paylaş") { confirmShare = true }
                            .disabled(shared || !store.canSend)
                            .confirmationDialog("Bu özeti sohbete gönder?", isPresented: $confirmShare, titleVisibility: .visible) {
                                Button("Paylaş") { share() }
                            }
                    } else if busy {
                        ProgressView()
                    } else if status == nil {
                        Text("Henüz mail özeti yok.")
                            .foregroundStyle(.secondary)
                    }
                    if let status { Text(status).foregroundStyle(.secondary) }
                    Button("Yenile") { Task { await refresh() } }
                        .disabled(busy)
                } header: {
                    Text("Kişisel önizleme")
                } footer: {
                    Text("Okul maillerin Google'da özetlenir; özet sunucuda şifreli bekler ve yalnızca bu telefon açabilir. Sohbette paylaştığın özet, diğer mesajlar gibi uçtan uca şifrelidir.")
                }
                Section {
                    if connected {
                        Label("Okul mailin bağlı. Özet her saat yenilenir.", systemImage: "checkmark.circle")
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
            .navigationTitle("Mail Özeti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .task { await refresh() }
            // Back from Safari after connecting: the first digest may be waiting.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await refresh() } }
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
                return
            }
            #endif
            let latest = try await client.draft()
            if draft?.shareText != latest?.shareText { shared = false }
            draft = latest
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
            shared = false
            status = nil
            storedConnected = true
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
            status = "Özet sohbete eklendi."
        case .failure:
            status = "Özet sohbete gönderilemedi."
        }
    }
}
