import SwiftUI

struct MainTabView: View {
    let model: AppModel
    let pair: PairInfo

    @State private var chat: PairChatModel?
    @State private var player = HeartbeatPlayer()

    private var myID: String { model.myID ?? "" }
    private var partnerID: String? { pair.memberIDs.first { $0 != myID } }
    private var myBPM: Int { pair.bpm[myID] ?? 72 }
    private var partnerBPM: Int { partnerID.flatMap { pair.bpm[$0] } ?? 72 }

    var body: some View {
        Group {
            if let chat {
                TabView {
                    HomeScreen(chat: chat, myBPM: myBPM, partnerBPM: partnerBPM)
                        .tabItem { Label("Ana Sayfa", systemImage: "house") }
                    ConversationView(chat: chat, myBPM: myBPM)
                        .tabItem { Label("Sohbet", systemImage: "bubble.left.and.bubble.right") }
                    UsScreen(model: model, partnerBPM: partnerBPM, myBPM: myBPM)
                        .tabItem { Label("Biz", systemImage: "heart") }
                }
                .onChange(of: chat.incomingHeartbeat) { _, bpm in
                    guard let bpm else { return }
                    try? player.play(bpm: Double(bpm), duration: 10)
                    chat.incomingHeartbeat = nil
                }
                .alert("Watchlink", isPresented: Binding(
                    get: { chat.errorMessage != nil },
                    set: { if !$0 { chat.errorMessage = nil } }
                )) {
                    Button("Tamam", role: .cancel) { }
                } message: { Text(chat.errorMessage ?? "") }
            } else {
                ProgressView()
            }
        }
        .task(id: pair.id) {
            chat?.stop()
            let newChat = PairChatModel(backend: model.backend, pairID: pair.id, myID: myID)
            newChat.start()
            chat = newChat
        }
    }
}

// MARK: - Home

private struct HomeScreen: View {
    let chat: PairChatModel
    let myBPM: Int
    let partnerBPM: Int

    private var lastFromPartner: BackendMessage? { chat.messages.last(where: { !chat.isMine($0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Watchlink").font(.system(size: 28, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(WatchlinkStyle.online).frame(width: 7, height: 7)
                    Text("Bağlı").font(.system(size: 12)).foregroundStyle(WatchlinkStyle.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Son mesaj").font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
                Text(preview(lastFromPartner)).font(.system(size: 17)).lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 18))

            Spacer()

            Button { Task { await chat.sendHeartbeat(bpm: myBPM) } } label: {
                Label("Kalp atışımı gönder", systemImage: "heart.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 56)
            }
            .buttonStyle(.plain)
            .foregroundStyle(WatchlinkStyle.background)
            .background(WatchlinkStyle.tint, in: RoundedRectangle(cornerRadius: 16))
            .disabled(chat.sending)
        }
        .padding(24)
        .background(WatchlinkStyle.background.ignoresSafeArea())
    }

    private func preview(_ message: BackendMessage?) -> String {
        switch message?.kind {
        case .text(let text): return text
        case .photo: return "📷 Fotoğraf"
        case .heartbeat: return "💚 Kalp atışı"
        case nil: return "Henüz bir şey yok."
        }
    }
}

// MARK: - Us

private struct UsScreen: View {
    let model: AppModel
    let partnerBPM: Int
    let myBPM: Int
    @State private var editingBPM: Int?

    var body: some View {
        VStack(spacing: 0) {
            HeartbeatView(bpm: Double(partnerBPM))
            VStack(spacing: 10) {
                Stepper(value: Binding(get: { editingBPM ?? myBPM }, set: { editingBPM = $0 }), in: 40...180) {
                    Text("Benim ritmim: \(editingBPM ?? myBPM) bpm").font(.system(size: 15))
                }
                if let editingBPM, editingBPM != myBPM {
                    WatchlinkPrimaryButton(title: "Ritmimi kaydet") {
                        Task { await model.saveMyBPM(editingBPM); self.editingBPM = nil }
                    }
                }
                Button("Çıkış yap") { model.signOut() }
                    .font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary).padding(.top, 6)
            }
            .padding(24)
        }
        .background(WatchlinkStyle.background.ignoresSafeArea())
    }
}
