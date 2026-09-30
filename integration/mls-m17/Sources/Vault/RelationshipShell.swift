import SwiftUI

/// The product shell, reached only from the root's established `.chats` state.
/// Every security root state (pairing, identity review, unavailable, reset
/// required) still replaces this whole view in WatchlinkRootView.
struct RelationshipShell: View {
    enum Destination: CaseIterable, Hashable {
        case home, chat, us

        var title: String {
            switch self {
            case .home: return "Home"
            case .chat: return "Chat"
            case .us: return "Us"
            }
        }

        var symbol: String {
            switch self {
            case .home: return "house"
            case .chat: return "bubble.left.and.bubble.right"
            case .us: return "person.2"
            }
        }
    }

    let store: WatchlinkStore
    @State private var destination = Destination.home
    /// Created once in `.task`: the root re-renders on every transport refresh,
    /// and an inline initial value would reload persistence each time.
    @State private var relationship: RelationshipStore?

    /// True whenever sending is not fully available. Nothing in the product layer can suppress it.
    static func showsSecurityNotice(canSend: Bool, connected: Bool) -> Bool { !canSend || !connected }

    var body: some View {
        VStack(spacing: 0) {
            if Self.showsSecurityNotice(canSend: store.canSend, connected: store.connectionAvailable) {
                SecurityNotice(store: store)
            }
            TabView(selection: $destination) {
                ForEach(Destination.allCases, id: \.self) { destination in
                    content(for: destination)
                        .tabItem { Label(destination.title, systemImage: destination.symbol) }
                        .tag(destination)
                }
            }
            .tint(WatchlinkStyle.tint)
        }
        .task { if relationship == nil { relationship = RelationshipStore() } }
    }

    @ViewBuilder private func content(for destination: Destination) -> some View {
        if let relationship {
            switch destination {
            case .home: HomeView(store: store, relationship: relationship) { self.destination = .chat }
            case .chat: ChatScreen(store: store, partnerName: relationship.snapshot.profile.partner.shownName)
            case .us: UsPlaceholder(relationship: relationship)
            }
        } else {
            WatchlinkStyle.background.ignoresSafeArea()
        }
    }
}

extension Person {
    private var name: String { nickname.isEmpty ? displayName : nickname }
    var shownName: String { name.isEmpty ? "Your partner" : name }
    var initial: String { name.prefix(1).uppercased() }
}

/// Security-owned wording (SecurityStatusView) plus what it means for sending.
private struct SecurityNotice: View {
    let store: WatchlinkStore
    var body: some View {
        VStack(alignment: .leading, spacing: WatchlinkStyle.Space.xs) {
            SecurityStatusView(state: store.securityState, connected: store.connectionAvailable)
            Text(store.canSend ? "Messages will send when the connection returns."
                               : "Sending is paused until the secure link is ready.")
                .font(WatchlinkStyle.Typography.caption)
                .foregroundStyle(WatchlinkStyle.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WatchlinkStyle.Space.xl)
        .padding(.vertical, WatchlinkStyle.Space.m)
        .background(WatchlinkStyle.soft)
        .accessibilityElement(children: .combine)
    }
}

/// Stage 3 replaces this with the real Us space.
private struct UsPlaceholder: View {
    let relationship: RelationshipStore
    var body: some View {
        let profile = relationship.snapshot.profile
        VStack(spacing: WatchlinkStyle.Space.xl) {
            Spacer()
            HStack(spacing: -WatchlinkStyle.Space.s) {
                initial(profile.me.initial)
                initial(profile.partner.initial)
            }
            .accessibilityHidden(true)
            VStack(spacing: WatchlinkStyle.Space.s) {
                Text("Us").font(WatchlinkStyle.Typography.title)
                Text("Moments, letters and the dates that matter will gather here, quietly, over time.")
                    .font(WatchlinkStyle.Typography.secondary)
                    .foregroundStyle(WatchlinkStyle.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            Spacer()
        }
        .padding(WatchlinkStyle.Space.xl)
        .frame(maxWidth: .infinity)
        .background(WatchlinkStyle.background.ignoresSafeArea())
    }

    private func initial(_ letter: String) -> some View {
        Text(letter)
            .font(WatchlinkStyle.Typography.heading)
            .foregroundStyle(WatchlinkStyle.tint)
            .frame(width: 56, height: 56)
            .background(WatchlinkStyle.soft, in: Circle())
            .overlay(Circle().stroke(WatchlinkStyle.background, lineWidth: 3))
    }
}
