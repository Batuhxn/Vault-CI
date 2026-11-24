import PhotosUI
import SwiftUI

struct ConversationView: View {
    let chat: PairChatModel
    let myBPM: Int

    @State private var draft = ""
    @State private var pickedPhoto: PhotosPickerItem?
    @FocusState private var composing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if chat.messages.isEmpty {
                            Text("Henüz mesaj yok. İlk mesajı sen gönder.")
                                .font(.system(size: 15)).foregroundStyle(WatchlinkStyle.secondary)
                                .padding(.top, 60)
                        }
                        ForEach(chat.messages) { message in
                            MessageRow(chat: chat, message: message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.last?.id) { _, last in
                    guard let last else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onAppear { if let last = chat.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }

            Divider().overlay(WatchlinkStyle.hairline)
            composer
        }
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await chat.send(photo: data) }
                pickedPhoto = nil
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Image(systemName: "photo").font(.system(size: 20, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            Button { Task { await chat.sendHeartbeat(bpm: myBPM) } } label: {
                Image(systemName: "heart.fill").font(.system(size: 18))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Kalp atışını gönder")

            TextField("Mesaj", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($composing)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 20))

            Button {
                let text = draft
                draft = ""
                Task { await chat.send(text: text) }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WatchlinkStyle.background)
                    .frame(width: 36, height: 36)
                    .background(WatchlinkStyle.tint, in: Circle())
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
        }
        .foregroundStyle(WatchlinkStyle.tint)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { if chat.sending { ProgressView().scaleEffect(0.6).offset(y: -16) } }
    }
}

private struct MessageRow: View {
    let chat: PairChatModel
    let message: BackendMessage

    private var mine: Bool { chat.isMine(message) }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 56) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                content
                if let date = message.createdAt {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 11)).foregroundStyle(WatchlinkStyle.secondary)
                        .padding(.horizontal, 4)
                }
            }
            if !mine { Spacer(minLength: 56) }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.kind {
        case .text(let text):
            Text(text)
                .font(.system(size: 17))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(mine ? WatchlinkStyle.sent : WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 18))
        case .photo(let photoID):
            PhotoBubble(chat: chat, photoID: photoID)
        case .heartbeat(let bpm):
            Label(mine ? "Kalp atışını gönderdin · \(bpm)" : "Kalp atışı · \(bpm) bpm", systemImage: "heart.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WatchlinkStyle.tint)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(WatchlinkStyle.soft, in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct PhotoBubble: View {
    let chat: PairChatModel
    let photoID: String
    @State private var image: UIImage?
    @State private var fullScreen = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack { WatchlinkStyle.surface; ProgressView() }
            }
        }
        .frame(width: 220, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { if image != nil { fullScreen = true } }
        .task { image = await chat.image(for: photoID) }
        .fullScreenCover(isPresented: $fullScreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                Button { fullScreen = false } label: {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                }.padding()
            }
        }
    }
}
