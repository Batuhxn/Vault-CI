import SwiftUI

struct ChatsHomeView: View {
    let store: WatchlinkStore
    @State private var showConversation = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watchlink").font(.system(size: 28, weight: .semibold))
                    SecurityStatusView(state: store.securityState)
                }
                Spacer()
                Text("B").font(.system(size: 13, weight: .semibold)).foregroundStyle(WatchlinkStyle.tint)
                    .frame(width: 36, height: 36).background(WatchlinkStyle.soft, in: Circle())
                    .accessibilityLabel("Settings")
            }.padding(.horizontal, 24).padding(.vertical, 15)
            Divider().overlay(WatchlinkStyle.hairline)
            if store.messages.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28))
                    Text("No conversations yet.").font(.system(size: 17, weight: .semibold))
                    Text("Your linked conversations will appear here.").font(.system(size: 15))
                }.foregroundStyle(WatchlinkStyle.secondary)
                Spacer()
            } else {
                Button { showConversation = true } label: {
                    HStack(spacing: 14) {
                        Text("E").font(.system(size: 16, weight: .semibold)).foregroundStyle(WatchlinkStyle.tint)
                            .frame(width: 48, height: 48).background(WatchlinkStyle.soft, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Linked device").font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchlinkStyle.text)
                            Text(store.messages.last?.text ?? "").font(.system(size: 15))
                                .foregroundStyle(WatchlinkStyle.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
                    }.padding(.horizontal, 24).padding(.vertical, 14)
                }.buttonStyle(.plain)
                Spacer()
            }
        }
        .sheet(isPresented: $showConversation) { ChatView(store: store) }
    }
}

struct SecurityStatusView: View {
    let state: SecurityState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state == .secure ? WatchlinkStyle.online : WatchlinkStyle.away)
                .frame(width: 6, height: 6)
            Text(label).font(.system(size: 12))
        }.foregroundStyle(WatchlinkStyle.secondary)
        .accessibilityElement(children: .combine)
    }
    private var label: String {
        switch state {
        case .secure: return "Connected"
        case .identityChanged: return "Review security"
        case .pairing, .establishingSecureSession: return "Connecting"
        case .notPaired: return "Not linked"
        case .unavailable, .error: return "Unavailable"
        }
    }
}

struct ChatView: View {
    let store: WatchlinkStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var showAttachmentInfo = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WatchlinkStyle.hairline)
            if store.securityState == .identityChanged {
                securityBanner("Security identity changed", "Sending is paused. Review security before continuing.")
            } else if !store.canSend {
                securityBanner("Secure messaging unavailable", "Sending will be available when a secure link is ready.")
            }
            timeline
            composer
        }
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .foregroundStyle(WatchlinkStyle.text)
        .alert("Attachments unavailable", isPresented: $showAttachmentInfo) {
            Button("OK", role: .cancel) { }
        } message: { Text("Attachments need a secure link before they can be sent.") }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44) }
                .accessibilityLabel("Back")
            Spacer()
            VStack(spacing: 1) {
                Text("Linked device").font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchlinkStyle.text)
                SecurityStatusView(state: store.securityState)
            }
            Spacer()
            Text("L").font(.system(size: 12, weight: .semibold)).foregroundStyle(WatchlinkStyle.tint)
                .frame(width: 32, height: 32).background(WatchlinkStyle.soft, in: Circle())
                .frame(width: 44, height: 44)
                .accessibilityLabel("Link information")
        }
        .foregroundStyle(WatchlinkStyle.tint)
        .padding(.horizontal, 12).frame(height: 52)
    }

    private var timeline: some View {
        Group {
            if store.messages.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left").font(.system(size: 28))
                    VStack(spacing: 4) {
                        Text("No messages yet.").font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchlinkStyle.text)
                        Text("Your conversation will appear here.").font(.system(size: 15))
                    }
                }.foregroundStyle(WatchlinkStyle.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            Text("Today").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(WatchlinkStyle.secondary).padding(.vertical, 8)
                            ForEach(store.messages) { message in
                                LocalMessageBubble(message: message).id(message.id)
                                    .transition(.opacity.combined(with: .offset(y: 8)))
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: store.messages.count) { _, _ in
                        if let last = store.messages.last {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { showAttachmentInfo = true } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .medium))
                    .frame(width: 36, height: 36).background(WatchlinkStyle.surface2, in: Circle())
                    .frame(width: 44, height: 44)
            }.accessibilityLabel("Add attachment")
            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4).font(.system(size: 17))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(WatchlinkStyle.hairline, lineWidth: 0.5))
                .disabled(!store.canSend)
                .accessibilityHint(store.canSend ? "" : "Requires a secure link")
            Button {
                if case .success = store.send(draft) { draft = "" }
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(canSubmit ? WatchlinkStyle.tint : WatchlinkStyle.surface2, in: Circle())
                    .foregroundStyle(canSubmit ? WatchlinkStyle.background : WatchlinkStyle.secondary)
                    .frame(width: 44, height: 44)
            }
            .disabled(!canSubmit).accessibilityLabel("Send")
        }
        .foregroundStyle(WatchlinkStyle.secondary)
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(WatchlinkStyle.background)
    }

    private var canSubmit: Bool { store.canSend && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func securityBanner(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(WatchlinkStyle.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(WatchlinkStyle.soft)
    }
}

private struct LocalMessageBubble: View {
    let message: LocalMessage
    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 70) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 3) {
                Text(message.text).font(.system(size: 17))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(message.isMine ? WatchlinkStyle.sent : WatchlinkStyle.surface2,
                                in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: message.isMine ? 18 : 6,
                                                           bottomTrailingRadius: message.isMine ? 6 : 18, topTrailingRadius: 18))
                    .frame(maxWidth: 272, alignment: message.isMine ? .trailing : .leading)
                if message.isMine {
                    Text(deliveryLabel).font(.system(size: 12)).foregroundStyle(WatchlinkStyle.secondary)
                        .padding(.horizontal, 4)
                }
            }
            if !message.isMine { Spacer(minLength: 70) }
        }
    }
    private var deliveryLabel: String {
        switch message.delivery {
        case .pending: return "Pending"
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .failed: return "Failed"
        }
    }
}
