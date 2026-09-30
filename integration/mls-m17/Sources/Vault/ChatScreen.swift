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
    @FocusState private var composing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sender-side states only. M1.7 "sent" means the relay accepted the ciphertext,
    /// not that the partner received it, so nothing here ever says "Delivered".
    static func deliveryLabel(_ delivery: DeliveryState) -> String {
        switch delivery {
        case .pending, .sending: return "Sending"
        case .sent, .delivered: return "Sent"
        case .failed: return "Not sent"
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
        .alert("Message not sent", isPresented: Binding(get: { sendProblem != nil }, set: { if !$0 { sendProblem = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(sendProblem ?? "") }
        .onChange(of: focusRequested, initial: true) { _, requested in
            guard requested else { return }
            focusRequested = false
            if store.canSend { composing = true }
        }
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
            .accessibilityLabel("Private Space")
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
                        Text("The first word is yours.")
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
                TextField(store.canSend ? partner.writeTo : "Messaging paused", text: $draft, axis: .vertical)
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
                    .accessibilityLabel("Send")
                    .padding(.bottom, 4)
                    // Send is never greyed out: it emerges when there is something to send.
                    .wlTransition(.scale(scale: 0.6).combined(with: .opacity), reduceMotion: reduceMotion)
                }
            }
            .padding(.leading, 16)
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
                Text("That's too long to send as one message.")
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
            sendProblem = "That message is too long to send."
        case .failure:
            sendProblem = "Sending is paused until the secure link is ready."
        }
    }
}

extension Person {
    var writeTo: String { initial.isEmpty ? "Write a message" : "Write to \(shownName)" }
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
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
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
                MessageBubble(message: message, position: run.position(of: index))
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
struct MessageBubble: View {
    let message: LocalMessage
    let position: MessageRun.Position

    private static let radius: CGFloat = 20
    private static let joined: CGFloat = 7

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        Text(message.text)
            .font(.body)
            .foregroundStyle(Room.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(message.isMine ? Room.mine : Room.paper, in: shape)
            .overlay { if !message.isMine { shape.stroke(Room.ink.opacity(0.06), lineWidth: 1) } }
            .containerRelativeFrame(.horizontal, alignment: message.isMine ? .trailing : .leading) { width, _ in width * 0.76 }
            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
            .accessibilityLabel(message.isMine ? "You: \(message.text)" : message.text)
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
