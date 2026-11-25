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
    /// Back to Home: the header chevron and a swipe from the left edge.
    let goBack: () -> Void
    let onMoonFrame: (CGRect) -> Void

    @State private var draft = ""
    @State private var sendProblem: String?
    @State private var sentCount = 0
    @State private var pickedPhoto: PhotosPickerItem?
    /// Whether the end of the transcript is on screen (incoming messages only follow then).
    @State private var atBottom = true
    /// Voice: hold the mic to record, release to send, slide left to cancel.
    @State private var recorder = VoiceRecorder()
    @State private var micHeld = false
    @State private var micSlide: CGFloat = 0
    @State private var micHint = false
    /// The message being answered (shown above the composer until sent or dismissed).
    @State private var replyTarget: LocalMessage?
    private static let cancelDistance: CGFloat = 90
    @FocusState private var composing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    /// On screen (the partner sees "here", and what's shown counts as read).
    @State private var visible = false

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
        // Swipe from the left edge to go back, like a pushed screen. Simultaneous,
        // so the transcript keeps scrolling; only a clear rightward edge drag counts.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24, coordinateSpace: .global)
                .onEnded { value in
                    guard value.startLocation.x < 32,
                          value.translation.width > 80,
                          abs(value.translation.height) < value.translation.width else { return }
                    back()
                }
        )
        .sensoryFeedback(RelationshipMotion.sendFeedback, trigger: sentCount)
        .onAppear {
            visible = true
            store.setViewing(scenePhase == .active)
        }
        .onDisappear {
            visible = false
            store.setViewing(false)
            VoicePlayer.shared.stop()
            recorder.cancel()
        }
        .onChange(of: scenePhase) { _, phase in store.setViewing(visible && phase == .active) }
        .onChange(of: draft) { _, text in
            store.setTyping(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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

    private func back() {
        composing = false
        goBack()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Room.sageDeep)
                    .frame(width: 36, height: 36)
                    .background(Room.control, in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            .accessibilityLabel("Ana Sayfa'ya dön")
            ConversationHeader(partner: partner, state: store.securityState, connected: store.connectionAvailable,
                               presence: store.partnerHere ? .together : .unknown, typing: store.partnerTyping)
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
        .padding(.leading, 8)
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
                    if store.partnerTyping {
                        TypingBubble()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                            .wlTransition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottomLeading)), reduceMotion: reduceMotion)
                    }
                    // The true end of the conversation: what "scroll to the newest" aims at.
                    // Visible (or about to be) means the reader is at the bottom.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .environment(\.bubbleContext, BubbleContext(
                partnerName: store.partnerName.isEmpty ? partner.displayName : store.partnerName,
                canAct: store.canSend,
                react: { id, emoji in store.react(to: id, emoji: emoji) },
                reply: { message in
                    replyTarget = message
                    composing = true
                }))
            // Incoming messages settle on the same spring; sends are already inside withAnimation.
            .animation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion), value: store.messages.count)
            // Follow the newest message: always for our own sends, and for the partner's
            // only when already at the bottom (reading older messages is never interrupted).
            .onChange(of: store.messages.last?.id) { _, _ in
                guard let last = store.messages.last, last.isMine || atBottom else { return }
                scrollToBottom(proxy)
            }
            .onChange(of: store.partnerTyping) { _, typing in
                if typing && atBottom { scrollToBottom(proxy) }
            }
            // Opening the keyboard shrinks the view: keep the newest message in sight.
            .onChange(of: composing) { _, isComposing in
                if isComposing { scrollToBottom(proxy) }
            }
        }
    }

    private static let bottomID = "watchlink.transcript.bottom"

    /// Waits a beat so the new bubble is laid out (LazyVStack measures it late),
    /// then glides to the true bottom instead of jumping to an estimate.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.38)) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        let ready = Self.canSubmit(draft: draft, canSend: store.canSend)
        let tooLong = draft.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > WatchlinkStore.maxMessageBytes
        return VStack(alignment: .leading, spacing: 4) {
            if let replyTarget, !recorder.isRecording {
                ReplyBar(target: replyTarget,
                         partnerName: store.partnerName.isEmpty ? partner.displayName : store.partnerName) {
                    self.replyTarget = nil
                }
                .wlTransition(.move(edge: .bottom).combined(with: .opacity), reduceMotion: reduceMotion)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if recorder.isRecording {
                    RecordingStrip(elapsed: recorder.elapsed, levels: recorder.levels,
                                   slide: micSlide, cancelDistance: Self.cancelDistance)
                        .wlTransition(.opacity, reduceMotion: reduceMotion)
                } else {
                    if !composing { attachments }
                    TextField(store.canSend ? partner.writeTo : "Mesajlaşma duraklatıldı", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.body)
                        .foregroundStyle(Room.ink)
                        .focused($composing)
                        .disabled(!store.canSend)
                        .padding(.vertical, 11)
                }
                // The mic keeps its place (and identity) while recording, so the hold isn't lost.
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
                } else if store.canSend {
                    micButton
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
            if micHint {
                Text("Kaydetmek için basılı tut, göndermek için bırak.")
                    .font(.caption)
                    .foregroundStyle(Room.ink3)
                    .padding(.leading, 16)
                    .wlTransition(.opacity, reduceMotion: reduceMotion)
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
        .animation(RelationshipMotion.resolve(RelationshipMotion.softSmall, reduceMotion: reduceMotion), value: recorder.isRecording)
        .animation(RelationshipMotion.resolve(RelationshipMotion.softSmall, reduceMotion: reduceMotion), value: micHint)
        .animation(RelationshipMotion.resolve(RelationshipMotion.softSmall, reduceMotion: reduceMotion), value: replyTarget?.id)
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.isRecording)
        .task { recorder.onLimit = { finishRecording(send: true) } }
    }

    private var micButton: some View {
        let recording = recorder.isRecording
        return Image(systemName: recording ? "mic.fill" : "mic")
            .font(.body.weight(.semibold))
            .foregroundStyle(recording ? Room.cream : Room.sageDeep)
            .frame(width: 36, height: 36)
            .background(recording ? Room.sage : Color.clear, in: Circle())
            .scaleEffect(recording && !reduceMotion ? 1.3 : 1)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !micHeld {
                            micHeld = true
                            beginRecording()
                        }
                        micSlide = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        micHeld = false
                        finishRecording(send: value.translation.width > -Self.cancelDistance)
                        micSlide = 0
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(recording ? "Kaydı gönder" : "Sesli mesaj kaydet")
            .accessibilityAddTraits(.isButton)
            // VoiceOver can't hold and slide: a double-tap starts, another sends.
            .accessibilityAction {
                if recorder.isRecording { finishRecording(send: true) } else { beginRecording() }
            }
            .padding(.bottom, 4)
    }

    private func beginRecording() {
        composing = false
        VoicePlayer.shared.stop()
        Task {
            guard await recorder.start() else {
                micHeld = false
                sendProblem = "Mikrofona erişilemedi. Ayarlar → Watchlink → Mikrofon'dan izin verebilirsin."
                return
            }
            // Let go before recording began (a tap, or the permission prompt): nothing to send.
            if !micHeld && !UIAccessibility.isVoiceOverRunning {
                recorder.cancel()
                showMicHint()
            }
        }
    }

    private func finishRecording(send: Bool) {
        guard recorder.isRecording else { return }
        guard send else { recorder.cancel(); return }
        guard let recording = recorder.stop() else { showMicHint(); return }
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) {
            if store.sendVoice(recording) { sentCount += 1 } else { sendProblem = "Sesli mesaj gönderilemedi." }
        }
    }

    private func showMicHint() {
        micHint = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            micHint = false
        }
    }

    /// The Letter. Nothing enters the transcript here: the store appends only
    /// what its send path accepted, inside this animation, and the bubble's
    /// insertion transition makes it rise out of the composer.
    private func send() {
        let text = draft
        var result: Result<UUID, SecurityFailure> = .failure(.sessionNotSecure)
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) {
            result = store.send(text, replyTo: replyTarget?.id)
            if case .success = result { replyTarget = nil }
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
        case .sent, .delivered: return last.seen ? "\(time) · Görüldü" : time
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
    @Environment(\.bubbleContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Swipe right to reply: how far the bubble has followed the finger.
    @State private var swipe: CGFloat = 0

    private static let radius: CGFloat = 20
    private static let joined: CGFloat = 7
    private static let replyDistance: CGFloat = 56
    static let reactionChoices = ["❤️", "😂", "😮", "😢"]

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        content(shape)
            .overlay(alignment: message.isMine ? .bottomLeading : .bottomTrailing) {
                if !message.reactions.isEmpty {
                    ReactionPill(reactions: message.reactions)
                        .offset(x: message.isMine ? -6 : 6, y: 14)
                        .wlTransition(.scale(scale: 0.4).combined(with: .opacity), reduceMotion: reduceMotion)
                }
            }
            .padding(.bottom, message.reactions.isEmpty ? 0 : 14)
            .animation(RelationshipMotion.resolve(RelationshipMotion.softSmall, reduceMotion: reduceMotion), value: message.reactions)
            .contentShape(.contextMenuPreview, shape)
            .contextMenu { if context.canAct { menu } }
            .onTapGesture(count: 2) {
                guard context.canAct else { return }
                context.react(message.id, "❤️")
            }
            .offset(x: swipe)
            .background(alignment: .leading) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.footnote)
                    .foregroundStyle(Room.sage)
                    .opacity(Double(min(swipe / Self.replyDistance, 1)))
                    .scaleEffect(swipe >= Self.replyDistance ? 1.15 : 0.85)
                    .offset(x: -22)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { value in
                        guard context.canAct, value.translation.width > 0,
                              value.translation.width > abs(value.translation.height) * 1.6 else { return }
                        swipe = min(value.translation.width * 0.7, Self.replyDistance + 14)
                    }
                    .onEnded { _ in
                        if swipe >= Self.replyDistance { context.reply(message) }
                        withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) { swipe = 0 }
                    }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: swipe >= Self.replyDistance)
            .accessibilityAction(named: "Yanıtla") { context.reply(message) }
            .accessibilityAction(named: "Kalp bırak") { context.react(message.id, "❤️") }
            .containerRelativeFrame(.horizontal, alignment: message.isMine ? .trailing : .leading) { width, _ in width * 0.76 }
            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
    }

    @ViewBuilder private func content(_ shape: UnevenRoundedRectangle) -> some View {
        switch message.kind {
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                if let quote = message.quote {
                    QuoteView(quote: quote, partnerName: context.partnerName)
                }
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(Room.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.isMine ? Room.mine : Room.paper, in: shape)
            .overlay { if !message.isMine { shape.stroke(Room.ink.opacity(0.06), lineWidth: 1) } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
        case .photo(let photoID):
            PhotoBubble(photoID: photoID, shape: shape)
                .accessibilityLabel(message.isMine ? "Bir fotoğraf gönderdin" : "Fotoğraf")
        case .heartbeat(let bpm):
            HeartbeatBubble(bpm: bpm, mine: message.isMine, shape: shape)
        case .voice(let voiceID, let seconds, let wave):
            VoiceBubble(voiceID: voiceID, seconds: seconds, wave: wave, mine: message.isMine, shape: shape)
        }
    }

    @ViewBuilder private var menu: some View {
        ControlGroup {
            ForEach(Self.reactionChoices, id: \.self) { emoji in
                Button(emoji) { context.react(message.id, emoji) }
            }
        }
        .controlGroupStyle(.palette)
        Button { context.reply(message) } label: { Label("Yanıtla", systemImage: "arrowshape.turn.up.left") }
        if case .text = message.kind {
            Button { UIPasteboard.general.string = message.text } label: { Label("Kopyala", systemImage: "doc.on.doc") }
        }
    }

    private var accessibilityText: String {
        var parts = [message.isMine ? "Sen: \(message.text)" : message.text]
        if let quote = message.quote { parts.insert("Yanıt: \(quote.snippet)", at: 0) }
        for reaction in message.reactions { parts.append(reaction.mine ? "Tepkin \(reaction.emoji)" : "Tepki \(reaction.emoji)") }
        return parts.joined(separator: ". ")
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
                if let image { ZoomablePhoto(image: image) { fullScreen = false } }
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

/// What a bubble needs from the conversation: who the partner is, and how to react or reply.
struct BubbleContext {
    var partnerName = ""
    var canAct = false
    var react: (UUID, String) -> Void = { _, _ in }
    var reply: (LocalMessage) -> Void = { _ in }
}

private struct BubbleContextKey: EnvironmentKey {
    static let defaultValue = BubbleContext()
}

extension EnvironmentValues {
    var bubbleContext: BubbleContext {
        get { self[BubbleContextKey.self] }
        set { self[BubbleContextKey.self] = newValue }
    }
}

/// The quoted message inside a reply: a sage rule, who wrote it, one line of it.
private struct QuoteView: View {
    let quote: LocalMessage.Quote
    let partnerName: String

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(Room.sage).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.mine ? "Sen" : (partnerName.isEmpty ? "O" : partnerName))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Room.sageDeep)
                Text(quote.snippet)
                    .font(.footnote)
                    .foregroundStyle(Room.ink2)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
    }
}

/// Reactions sit on the bubble's lower corner: one emoji, or one with "2" when both chose it.
private struct ReactionPill: View {
    let reactions: [LocalMessage.Reaction]

    var body: some View {
        let emojis = reactions.map(\.emoji)
        let same = Set(emojis).count == 1 && emojis.count == 2
        HStack(spacing: 2) {
            if same {
                Text(emojis[0])
                Text("2").font(.caption2.weight(.semibold)).foregroundStyle(Room.ink2)
            } else {
                ForEach(Array(emojis.enumerated()), id: \.offset) { _, emoji in Text(emoji) }
            }
        }
        .font(.footnote)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Room.paper, in: Capsule())
        .overlay(Capsule().stroke(Room.hairline, lineWidth: 1))
        .shadow(color: Room.ink.opacity(0.08), radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}

/// Above the composer while answering a message.
private struct ReplyBar: View {
    let target: LocalMessage
    let partnerName: String
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(Room.sage).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(target.isMine ? "Kendine yanıt" : "\(partnerName.isEmpty ? "Mesaja" : partnerName) · yanıt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Room.sageDeep)
                Text(target.snippet)
                    .font(.footnote)
                    .foregroundStyle(Room.ink2)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Room.ink3)
                    .frame(width: 30, height: 30)
                    .background(Room.control, in: Circle())
            }
            .accessibilityLabel("Yanıtı iptal et")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Room.paper.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Room.ink.opacity(0.07), lineWidth: 1))
    }
}

/// Three soft dots while the partner writes.
private struct TypingBubble: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = reduceMotion ? 0 : sin((t * 5) - Double(index) * 0.9)
                    Circle()
                        .fill(Room.ink3.opacity(0.45 + 0.35 * max(phase, 0)))
                        .frame(width: 7, height: 7)
                        .offset(y: -3 * max(phase, 0))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Room.paper, in: Capsule())
        .overlay(Capsule().stroke(Room.ink.opacity(0.06), lineWidth: 1))
        .accessibilityLabel("Yazıyor")
    }
}

/// A voice message: play/pause, the waveform filling as it plays, and its length.
private struct VoiceBubble: View {
    let voiceID: String
    let seconds: Double
    let wave: [UInt8]
    let mine: Bool
    let shape: UnevenRoundedRectangle
    @Environment(WatchlinkStore.self) private var store
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        let player = VoicePlayer.shared
        let playing = player.playingID == voiceID
        HStack(spacing: 10) {
            Button { Task { await toggle() } } label: {
                ZStack {
                    if loading {
                        ProgressView().tint(Room.cream)
                    } else {
                        Image(systemName: failed ? "exclamationmark" : (playing ? "pause.fill" : "play.fill"))
                            .font(.footnote.weight(.bold))
                    }
                }
                .foregroundStyle(Room.cream)
                .frame(width: 34, height: 34)
                .background(Room.sage, in: Circle())
            }
            .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            WaveBars(levels: wave.map { Float($0) / 255 }, progress: playing ? player.progress : 0)
                .frame(height: 26)
            Text(voiceTime(playing ? seconds * player.progress : seconds))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Room.ink3)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(mine ? Room.mine : Room.paper, in: shape)
        .overlay { if !mine { shape.stroke(Room.ink.opacity(0.06), lineWidth: 1) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mine ? "Sesli mesajın" : "Sesli mesaj"), \(Int(seconds.rounded())) saniye")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { Task { await toggle() } }
    }

    private func toggle() async {
        let player = VoicePlayer.shared
        if player.playingID == voiceID { player.stop(); return }
        loading = true
        let data = await store.voice(for: voiceID)
        loading = false
        failed = data == nil
        if let data { player.toggle(id: voiceID, data: data) }
    }
}

/// Bars of a recorded waveform; the played part takes the sage tone.
private struct WaveBars: View {
    let levels: [Float]
    var progress: Double = 0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(Double(index) / Double(max(levels.count, 1)) < progress ? Room.sage : Room.ink3.opacity(0.35))
                    .frame(width: 2.5, height: 3 + CGFloat(level) * 23)
            }
        }
        .accessibilityHidden(true)
    }
}

/// While the mic is held: a pulse, the time, the live input, and how to cancel.
private struct RecordingStrip: View {
    let elapsed: TimeInterval
    let levels: [Float]
    let slide: CGFloat
    let cancelDistance: CGFloat
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cancelling = slide < -cancelDistance
        HStack(spacing: 10) {
            Circle()
                .fill(Room.blocking)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                }
            Text(voiceTime(elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(Room.ink)
            HStack(spacing: 2) {
                ForEach(Array(levels.suffix(24).enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(Room.sage.opacity(0.8))
                        .frame(width: 2.5, height: 3 + CGFloat(level) * 19)
                }
            }
            .frame(height: 22)
            Spacer(minLength: 4)
            Label(cancelling ? "Bırak, iptal" : "İptal", systemImage: "chevron.left")
                .font(.footnote)
                .foregroundStyle(cancelling ? Room.blocking : Room.ink3)
                .offset(x: max(slide * 0.5, -50))
        }
        .padding(.leading, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kaydediliyor, \(Int(elapsed)) saniye")
    }
}

/// "0:07", "1:42"
private func voiceTime(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

/// Full-screen photo on a native UIScrollView, so it feels like Photos/WhatsApp:
/// the pinch is anchored under the fingers, two fingers pan while zooming,
/// edges bounce, double-tap zooms to the tapped point, and a downward swipe at
/// normal size closes it.
private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(close: close) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutAwareScrollView()
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout() }
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 5
        scroll.minimumZoomScale = 1
        scroll.bouncesZoom = true
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scroll

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let dismiss = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissPan(_:)))
        dismiss.delegate = context.coordinator
        scroll.addGestureRecognizer(dismiss)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.layout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let close: () -> Void
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        private var laidOutSize: CGSize = .zero

        init(close: @escaping () -> Void) { self.close = close }

        /// Fit the image to the screen at zoom 1; re-run when the bounds change.
        func layout() {
            guard let scroll = scrollView, let imageView, let image = imageView.image else { return }
            let bounds = scroll.bounds.size
            guard bounds.width > 0, bounds != laidOutSize else { return }
            laidOutSize = bounds
            scroll.zoomScale = 1
            let ratio = min(bounds.width / image.size.width, bounds.height / image.size.height)
            imageView.frame = CGRect(x: 0, y: 0, width: image.size.width * ratio, height: image.size.height * ratio)
            scroll.contentSize = imageView.frame.size
            center()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { center() }

        /// The dismiss pan and the scroll view's own pan may run together.
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Keeps a smaller-than-screen image centred instead of pinned top-left.
        private func center() {
            guard let scroll = scrollView, let imageView else { return }
            let x = max((scroll.bounds.width - imageView.frame.width) / 2, 0)
            let y = max((scroll.bounds.height - imageView.frame.height) / 2, 0)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = scrollView, let imageView else { return }
            if scroll.zoomScale > scroll.minimumZoomScale {
                scroll.setZoomScale(scroll.minimumZoomScale, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }

        /// Swipe down at normal size: the photo follows the finger, then closes or settles back.
        @objc func dismissPan(_ gesture: UIPanGestureRecognizer) {
            guard let scroll = scrollView, let imageView else { return }
            let dy = max(gesture.translation(in: scroll).y, 0)
            switch gesture.state {
            case .changed:
                imageView.transform = CGAffineTransform(translationX: 0, y: dy)
                scroll.alpha = 1 - min(dy / 600, 0.4)
            case .ended, .cancelled:
                if dy > 120 || gesture.velocity(in: scroll).y > 900 {
                    close()
                } else {
                    UIView.animate(withDuration: 0.25) {
                        imageView.transform = .identity
                        scroll.alpha = 1
                    }
                }
            default: break
            }
        }

        /// The dismiss pan only starts at normal size, moving mostly downward.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, pan.view === scrollView, pan !== scrollView?.panGestureRecognizer,
                  let scroll = scrollView else { return true }
            let velocity = pan.velocity(in: scroll)
            return scroll.zoomScale <= scroll.minimumZoomScale + 0.01 && velocity.y > abs(velocity.x)
        }
    }
}

/// Reports every layout pass, so the photo is fitted once the real size is known
/// (SwiftUI may create the view at zero size and never call update again).
private final class LayoutAwareScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
