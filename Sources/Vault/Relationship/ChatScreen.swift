import PhotosUI
import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// Chat presentation over WatchlinkStore only (messages, send, canSend,
/// securityState). The transcript lives where the store keeps it; nothing here persists it.
struct ChatScreen: View {
    let store: WatchlinkStore
    let partner: Person
    /// Set by Home's "Write to…" pill; consumed once to focus the composer.
    @Binding var focusRequested: Bool
    let openPrivate: () -> Void
    let onMoonFrame: (CGRect) -> Void

    @State private var draft = ""
    @State private var sendProblem: String?
    @State private var sentCount = 0
    @State private var pickedPhoto: PhotosPickerItem?
    @FocusState private var composing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sender-side states only. M1.7 "sent" means the relay accepted the ciphertext,
    /// not that the partner received it, so nothing here ever says "Delivered".
    static func deliveryLabel(_ delivery: DeliveryState) -> String {
        switch delivery {
        case .pending, .sending: return "Gönderiliyor"
        case .sent, .delivered: return "Gönderildi"
        case .failed: return "Gönderilemedi"
        }
    }

    static func canSubmit(draft: String, canSend: Bool) -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return canSend && !text.isEmpty && text.utf8.count <= WatchlinkStore.maxMessageBytes
    }

    /// The Letter only ever follows the store: the field clears when the send path
    /// accepted the message, and keeps the words on any failure.
    static func draftAfterSend(_ result: Result<UUID, SecurityFailure>, draft: String) -> String {
        if case .success = result { return "" }
        return draft
    }

    var body: some View {
        ScreenScaffold {
            transcript
                .safeAreaInset(edge: .top, spacing: 0) { header }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        // The conversation keeps its height while typing.
        .toolbar(composing ? .hidden : .visible, for: .tabBar)
        .sensoryFeedback(RelationshipMotion.sendFeedback, trigger: sentCount)
        .alert("Mesaj gönderilemedi", isPresented: Binding(get: { sendProblem != nil }, set: { if !$0 { sendProblem = nil } })) {
            Button("Tamam", role: .cancel) { }
        } message: { Text(sendProblem ?? "") }
        .onChange(of: focusRequested, initial: true) { _, requested in
            guard requested else { return }
            focusRequested = false
            if store.canSend { composing = true }
        }
        .onChange(of: pickedPhoto) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                pickedPhoto = nil
                guard let data else { return }
                if await store.sendPhoto(data) { sentCount += 1 } else { sendProblem = "Bu fotoğraf hazırlanamadı." }
            }
        }
    }

    /// Photo and heartbeat: two quiet round controls, the same family as the moon.
    private var attachments: some View {
        HStack(spacing: 2) {
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Image(systemName: "photo")
                    .font(.body)
                    .foregroundStyle(Room.sageDeep)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            .accessibilityLabel("Fotoğraf gönder")
            Button {
                withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) {
                    store.sendHeartbeat()
                }
                sentCount += 1
            } label: {
                Image(systemName: "heart.fill")
                    .font(.body)
                    .foregroundStyle(Room.sageDeep)
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            .accessibilityLabel("Kalp atışını gönder")
        }
        .disabled(!store.canSend)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ConversationHeader(partner: partner, state: store.securityState, connected: store.connectionAvailable)
            Spacer(minLength: 0)
            Button(action: openPrivate) {
                Image(systemName: "moon")
                    .font(.body)
                    .foregroundStyle(Room.sageDeep)
                    .frame(width: 40, height: 40)
                    .background(Room.control, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            .accessibilityLabel("Özel Alan")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onMoonFrame($0) }
        }
        .padding(.leading, screenMargin)
        .padding(.trailing, 12)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background {
            LinearGradient(stops: [.init(color: Room.cream, location: 0.78), .init(color: Room.cream.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder private var transcript: some View {
        let runs = MessageRun.group(store.messages)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if runs.isEmpty {
                        Text("İlk söz senin.")
                            .wlWhisper(size: 17)
                            .foregroundStyle(Room.ink3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    }
                    ForEach(runs) { run in
                        MessageRunView(run: run, reduceMotion: reduceMotion).id(run.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Incoming messages settle on the same spring; sends are already inside withAnimation.
            .animation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion), value: store.messages.count)
            .onChange(of: store.messages.count) { _, _ in
                guard let last = runs.last else { return }
                withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        let ready = Self.canSubmit(draft: draft, canSend: store.canSend)
        let tooLong = draft.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > WatchlinkStore.maxMessageBytes
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                if !composing { attachments }
                TextField(store.canSend ? partner.writeTo : "Mesajlaşma duraklatıldı", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.body)
                    .foregroundStyle(Room.ink)
                    .focused($composing)
                    .disabled(!store.canSend)
                    .padding(.vertical, 11)
                if ready {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Room.cream)
                            .frame(width: 36, height: 36)
                            .background(Room.sage, in: Circle())
                    }
                    .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
                    .accessibilityLabel("Gönder")
                    .padding(.bottom, 4)
                    // Send is never greyed out: it emerges when there is something to send.
                    .wlTransition(.scale(scale: 0.6).combined(with: .opacity), reduceMotion: reduceMotion)
                }
            }
            .padding(.leading, composing ? 16 : 6)
            .padding(.trailing, 5)
            .frame(minHeight: composing ? 48 : 44)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(composing ? Room.paper : Room.paper.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(composing ? Room.sage.opacity(0.3) : Room.ink.opacity(0.07), lineWidth: 1))
                    .shadow(color: Room.ink.opacity(composing ? 0.14 : 0.06), radius: composing ? 16 : 9, y: composing ? 10 : 6)
            }
            if tooLong {
                Text("Tek mesaj için çok uzun.")
                    .font(.caption)
                    .foregroundStyle(Room.ink3)
                    .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background {
            LinearGradient(stops: [.init(color: Room.cream.opacity(0), location: 0), .init(color: Room.cream, location: 0.3)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion), value: composing)
        .animation(RelationshipMotion.resolve(RelationshipMotion.softSmall, reduceMotion: reduceMotion), value: ready)
    }

    /// The Letter. Nothing enters the transcript here: the store appends only
    /// what its send path accepted, inside this animation, and the bubble's
    /// insertion transition makes it rise out of the composer.
    private func send() {
        let text = draft
        var result: Result<UUID, SecurityFailure> = .failure(.sessionNotSecure)
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) {
            result = store.send(text)
            draft = Self.draftAfterSend(result, draft: text)
        }
        switch result {
        case .success:
            sentCount += 1
        case .failure(.transportFailed):
            break  // the store shows it as "Not sent"; the words stay in the field, never retried as plaintext
        case .failure(.messageTooLarge):
            sendProblem = "Bu mesaj gönderilemeyecek kadar uzun."
        case .failure:
            sendProblem = "Partnerin katılana kadar gönderim duraklatıldı."
        }
    }
}

extension Person {
    var writeTo: String { initial.isEmpty ? "Bir mesaj yaz" : "\(shownName) için yaz" }
}

/// Consecutive messages from one sender within five minutes, on one day.
/// A failed message stands alone so its "Not sent" line is unambiguous.
struct MessageRun: Identifiable, Equatable {
    enum Position: Equatable { case single, first, middle, last }

    let messages: [LocalMessage]
    /// "Today", "Yesterday" or a date when this run opens a new day.
    let dayBreak: String?
    var id: UUID { messages[0].id }
    var isMine: Bool { messages[0].isMine }

    static let window: TimeInterval = 5 * 60

    static func group(_ messages: [LocalMessage], calendar: Calendar = .current, now: Date = Date()) -> [MessageRun] {
        var runs: [MessageRun] = []
        var current: [LocalMessage] = []
        var currentBreak: String?
        func flush() {
            if !current.isEmpty { runs.append(MessageRun(messages: current, dayBreak: currentBreak)) }
            current = []
        }
        for message in messages {
            let previous = current.last ?? runs.last?.messages.last
            let newDay = previous.map { !calendar.isDate($0.timestamp, inSameDayAs: message.timestamp) } ?? true
            let joins = current.last.map { last in
                last.isMine == message.isMine && !newDay
                    && message.timestamp.timeIntervalSince(last.timestamp) <= window
                    && last.delivery != .failed && message.delivery != .failed
            } ?? false
            if !joins {
                flush()
                currentBreak = newDay ? dayLabel(message.timestamp, calendar: calendar, now: now) : nil
            }
            current.append(message)
        }
        flush()
        return runs
    }

    static func dayLabel(_ date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Bugün" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Dün"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    func position(of index: Int) -> Position {
        switch (messages.count, index) {
        case (1, _): return .single
        case (_, 0): return .first
        case (_, messages.count - 1): return .last
        default: return .middle
        }
    }

    /// One line under the run: its time, plus a sender-side state only while it matters.
    var footer: String {
        let last = messages[messages.count - 1]
        let time = last.timestamp.formatted(date: .omitted, time: .shortened)
        guard last.isMine else { return time }
        switch last.delivery {
        case .pending, .sending, .failed: return "\(time) · \(ChatScreen.deliveryLabel(last.delivery))"
        case .sent, .delivered: return time
        }
    }
}

struct MessageRunView: View {
    let run: MessageRun
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: run.isMine ? .trailing : .leading, spacing: 3) {
            if let dayBreak = run.dayBreak {
                Text(dayBreak)
                    .wlWhisper()
                    .foregroundStyle(Room.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)
                    .padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(run.messages.enumerated()), id: \.element.id) { index, message in
                ConversationBubble(message: message, position: run.position(of: index))
                    .wlTransition(message.delivery == .failed ? .opacity : .letter(mine: message.isMine), reduceMotion: reduceMotion)
            }
            Text(run.footer)
                .font(.caption)
                .foregroundStyle(run.messages.last?.delivery == .failed ? Room.blocking : Room.ink3)
                .padding(.horizontal, 6)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: run.isMine ? .trailing : .leading)
        .padding(.top, 14)
    }
}

/// No tails, no ticks. Mine and theirs differ by side and tone; the corner that
/// meets a neighbour in the same run softens, so appending re-shapes the previous
/// bubble on the same spring.
struct ConversationBubble: View {
    let message: LocalMessage
    let position: MessageRun.Position

    private static let radius: CGFloat = 20
    private static let joined: CGFloat = 7

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        Group {
            switch message.kind {
            case .text:
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Room.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.isMine ? Room.mine : Room.paper, in: shape)
                    .overlay { if !message.isMine { shape.stroke(Room.ink.opacity(0.06), lineWidth: 1) } }
                    .accessibilityLabel(message.isMine ? "Sen: \(message.text)" : message.text)
            case .photo(let photoID):
                PhotoBubble(photoID: photoID, shape: shape)
                    .accessibilityLabel(message.isMine ? "Bir fotoğraf gönderdin" : "Fotoğraf")
            case .heartbeat(let bpm):
                HeartbeatBubble(bpm: bpm, mine: message.isMine, shape: shape)
            }
        }
        .containerRelativeFrame(.horizontal, alignment: message.isMine ? .trailing : .leading) { width, _ in width * 0.76 }
        .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
    }

    private var radii: RectangleCornerRadii {
        let r = Self.radius, j = Self.joined
        let top = position == .middle || position == .last
        let bottom = position == .middle || position == .first
        return message.isMine
            ? RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: bottom ? j : r, topTrailing: top ? j : r)
            : RectangleCornerRadii(topLeading: top ? j : r, bottomLeading: bottom ? j : r, bottomTrailing: r, topTrailing: r)
    }
}

/// A photo from the pair's Firestore photo documents, loaded when it scrolls in.
private struct PhotoBubble: View {
    let photoID: String
    let shape: UnevenRoundedRectangle
    @Environment(WatchlinkStore.self) private var store
    @State private var image: UIImage?
    @State private var fullScreen = false

    var body: some View {
        ZStack {
            Room.linen
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ProgressView().tint(Room.ink3)
            }
        }
        .frame(width: 220, height: 280)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { if image != nil { fullScreen = true } }
        .task(id: photoID) { image = await store.image(for: photoID) }
        .fullScreenCover(isPresented: $fullScreen) {
            ZStack(alignment: .topTrailing) {
                Room.night.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                Button { fullScreen = false } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .foregroundStyle(Room.nightText).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Kapat")
                .padding()
            }
        }
    }
}

/// A heartbeat in the conversation. Tap to feel it again.
private struct HeartbeatBubble: View {
    let bpm: Int
    let mine: Bool
    let shape: UnevenRoundedRectangle
    @State private var player = HeartbeatPlayer()

    var body: some View {
        Button { try? player.play(bpm: Double(bpm), duration: 8) } label: {
            HStack(spacing: 8) {
                Image(systemName: "heart.fill").foregroundStyle(Room.sage)
                Text(mine ? "Kalp atışın" : "Bir kalp atışı").foregroundStyle(Room.ink)
                Text("\(bpm) bpm").font(.footnote).foregroundStyle(Room.ink3)
            }
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Room.mist, in: shape)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel(mine ? "Kalp atışın, dakikada \(bpm) atım" : "Bir kalp atışı, dakikada \(bpm) atım. Hissetmek için dokun.")
    }
}
