import SwiftUI

@MainActor
struct MailDigestSheet: View {
    let store: WatchlinkStore
    let client: MailDigestClient

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MailDigest?
    @State private var ingestToken: String?
    @State private var busy = false
    @State private var status: String?
    @State private var confirmShare = false
    @State private var confirmDisconnect = false
    @State private var confirmReconnect = false
    @State private var shared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Kişisel önizleme") {
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
                }
                if !demo {
                    Section("Apps Script") {
                        if let ingestToken {
                            Text("Bu kodu kendi Apps Script projenin WATCHLINK_INGEST_TOKEN ayarına ekle.")
                            Text(ingestToken)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .privacySensitive()
                        }
                        Button("Bağlantı kodu oluştur") { confirmReconnect = true }
                            .disabled(busy)
                            .confirmationDialog("Apps Script bağlantısı kurulsun mu?", isPresented: $confirmReconnect, titleVisibility: .visible) {
                                Button("Kod oluştur") { Task { await register() } }
                            } message: {
                                Text("Yeni kod oluşturulduğunda önceki kod ve bekleyen özet silinir.")
                            }
                        Button("Bağlantıyı kes", role: .destructive) { confirmDisconnect = true }
                            .disabled(busy)
                            .confirmationDialog("Bağlantı ve bekleyen özet silinsin mi?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                                Button("Bağlantıyı kes", role: .destructive) { Task { await disconnect() } }
                            }
                    }
                }
            }
            .navigationTitle("Mail Özeti")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Bitti") { dismiss() } }
            }
            .task { await refresh() }
        }
    }

    private var demo: Bool {
        #if DEBUG
        DemoChatBackend.isOn
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

    @MainActor private func register() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            ingestToken = try await client.register()
            draft = nil
            shared = false
            status = nil
        } catch {
            status = "Bağlantı kodu oluşturulamadı."
        }
    }

    @MainActor private func disconnect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.disconnect()
            ingestToken = nil
            draft = nil
            shared = false
            status = "Apps Script bağlantısı kesildi."
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
