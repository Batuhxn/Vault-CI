import SwiftUI

/// Chat presentation over WatchlinkStore only (messages, send, canSend,
/// securityState). The transcript lives where the store keeps it; nothing here persists it.
struct ChatScreen: View {
    let store: WatchlinkStore
    let partnerName: String
    @State private var draft = ""
    @State private var showingPrivateSpace = false
    @State private var sendProblem: String?
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WatchlinkStyle.hairline)
            timeline
            composer
        }
        .background(WatchlinkStyle.background.ignoresSafeArea(edges: .top))
        .foregroundStyle(WatchlinkStyle.text)
        .sheet(isPresented: $showingPrivateSpace) { PrivateSpacePreview() }
        .alert("Message not sent", isPresented: Binding(get: { sendProblem != nil }, set: { if !$0 { sendProblem = nil } })) {
            Button("OK", role: .cancel) { }
        } message: { Text(sendProblem ?? "") }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(partnerName).font(WatchlinkStyle.Typography.heading)
                SecurityStatusView(state: store.securityState, connected: store.connectionAvailable)
            }
            Spacer()
            Button { showingPrivateSpace = true } label: {
                Image(systemName: "lock")
                    .font(WatchlinkStyle.Typography.body)
                    .foregroundStyle(WatchlinkStyle.tint)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Private Space")
        }
        .padding(.leading, WatchlinkStyle.Space.xl)
        .padding(.trailing, WatchlinkStyle.Space.s)
        .padding(.vertical, WatchlinkStyle.Space.s)
    }

    @ViewBuilder private var timeline: some View {
        if store.messages.isEmpty {
            VStack(spacing: WatchlinkStyle.Space.s) {
                Text("Say something small.").font(WatchlinkStyle.Typography.heading)
                Text("Messages are end-to-end encrypted between your two devices.")
                    .font(WatchlinkStyle.Typography.secondary)
                    .foregroundStyle(WatchlinkStyle.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(WatchlinkStyle.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let lastMine = store.messages.last { $0.isMine }?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: WatchlinkStyle.Space.xs) {
                        ForEach(store.messages) { message in
                            // Quiet: the status shows on the latest message of mine, and on any failure.
                            ChatBubble(message: message,
                                       status: message.isMine && (message.id == lastMine || message.delivery == .failed)
                                           ? Self.deliveryLabel(message.delivery) : nil)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, WatchlinkStyle.Space.l)
                    .padding(.vertical, WatchlinkStyle.Space.l)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) { _, _ in
                    guard let last = store.messages.last else { return }
                    withAnimation(WatchlinkStyle.Motion.standard(reduceMotion)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: WatchlinkStyle.Space.s) {
            TextField(store.canSend ? "Message" : "Sending is paused", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .font(WatchlinkStyle.Typography.body)
                .padding(.horizontal, WatchlinkStyle.Space.l)
                .padding(.vertical, 10)
                .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: WatchlinkStyle.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: WatchlinkStyle.Radius.card).stroke(WatchlinkStyle.hairline, lineWidth: 0.5))
                .disabled(!store.canSend)
            let ready = Self.canSubmit(draft: draft, canSend: store.canSend)
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(WatchlinkStyle.Typography.heading)
                    .foregroundStyle(ready ? WatchlinkStyle.background : WatchlinkStyle.secondary)
                    .frame(width: 36, height: 36)
                    .background(ready ? WatchlinkStyle.tint : WatchlinkStyle.surface2, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .disabled(!ready)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, WatchlinkStyle.Space.m)
        .padding(.vertical, WatchlinkStyle.Space.s)
    }

    private func send() {
        switch store.send(draft) {
        case .success:
            draft = ""
        case .failure(.transportFailed):
            draft = ""  // the store already shows it as "Not sent"; never retried as plaintext
        case .failure(.messageTooLarge):
            sendProblem = "That message is too long to send."
        case .failure:
            sendProblem = "Sending is paused until the secure link is ready."
        }
    }
}

private struct ChatBubble: View {
    let message: LocalMessage
    let status: String?
    var body: some View {
        VStack(alignment: message.isMine ? .trailing : .leading, spacing: 2) {
            Text(message.text)
                .font(WatchlinkStyle.Typography.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(message.isMine ? WatchlinkStyle.sent : WatchlinkStyle.surface,
                            in: RoundedRectangle(cornerRadius: WatchlinkStyle.Radius.card))
                .frame(maxWidth: 290, alignment: message.isMine ? .trailing : .leading)
            if let status {
                Text(status)
                    .font(WatchlinkStyle.Typography.caption)
                    .foregroundStyle(message.delivery == .failed ? WatchlinkStyle.danger : WatchlinkStyle.secondary)
                    .padding(.horizontal, WatchlinkStyle.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Placeholder only: no private content, no storage, no new crypto (Stage 5).
private struct PrivateSpacePreview: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: WatchlinkStyle.Space.l) {
            Spacer()
            Image(systemName: "lock").font(.largeTitle).foregroundStyle(WatchlinkStyle.tint)
            Text("Private Space").font(WatchlinkStyle.Typography.title)
            Text("A quieter room for things meant only for the two of you. It arrives in a later update.")
                .font(WatchlinkStyle.Typography.secondary)
                .foregroundStyle(WatchlinkStyle.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            Spacer()
            WatchlinkPrimaryButton(title: "Close") { dismiss() }
        }
        .padding(WatchlinkStyle.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .foregroundStyle(WatchlinkStyle.text)
        .preferredColorScheme(.dark)
    }
}
