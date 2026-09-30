import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// The product shell, reached only from the root's established `.chats` state.
/// Every security root state (pairing, identity review, unavailable, reset
/// required) still replaces this whole view in WatchlinkRootView.
///
/// One room, three layers: the native TabView, The Opening's proxy surface and
/// The Door. Cross-tab and full-screen moves live here because an unselected
/// TabView page isn't rendered, so nothing can match geometry across it.
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
            case .chat: return "bubble.left"
            case .us: return "circle.circle"  // nested rings, no hearts
            }
        }

        var order: Int { Self.allCases.firstIndex(of: self)! }
    }

    let store: WatchlinkStore
    @State private var destination = Destination.home
    /// -1 / +1: the side new content glides in from; 0: no glide (The Opening hands off).
    @State private var entrance: CGFloat = 0
    /// Created once in `.task`: the root re-renders on every transport refresh,
    /// and an inline initial value would reload persistence each time.
    @State private var relationship: RelationshipStore?
    @State private var composerFocusRequested = false

    // The Door
    @State private var privateOpen = false
    @State private var privateProgress: CGFloat = 0
    @State private var privateSettled = false
    @State private var moonFrame = CGRect.zero

    // The Opening
    @State private var surfaceFrame = CGRect.zero
    @State private var morphFrom: CGRect?
    @State private var morphExpanded = false
    @State private var roomSize = CGSize.zero
    @State private var contentTop: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True whenever sending is not fully available. Nothing in the product layer can suppress it.
    static func showsSecurityNotice(canSend: Bool, connected: Bool) -> Bool { !canSend || !connected }

    var body: some View {
        ZStack {
            // e0: the ground never moves, never shadows, never animates.
            Room.cream.ignoresSafeArea()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { roomSize = $0 }
            tabs
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY + $0.safeAreaInsets.top } action: { contentTop = $0 }
                .scaleEffect(reduceMotion ? 1 : 1 - 0.025 * privateProgress)
                .brightness(-0.3 * privateProgress)
                .accessibilityHidden(privateOpen)
            if let morphFrom, let relationship {
                OpeningProxy(from: morphFrom, expanded: morphExpanded, room: roomSize, top: contentTop,
                             partner: relationship.snapshot.profile.partner, store: store)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if privateOpen || privateProgress > 0 {
                PrivateSpaceLayer(progress: privateProgress, anchor: CGPoint(x: moonFrame.midX, y: moonFrame.midY),
                                  close: closePrivate)
            }
        }
        // Above every layer, including The Door: security is never hidden by the product.
        .safeAreaInset(edge: .top, spacing: 0) {
            if Self.showsSecurityNotice(canSend: store.canSend, connected: store.connectionAvailable) {
                SecurityNotice(store: store)
            }
        }
        // Light until a dark theme ships (no black fallback); dark only once the door is fully open.
        .preferredColorScheme(privateSettled ? .dark : .light)
        .sensoryFeedback(.selection, trigger: destination)
        .sensoryFeedback(RelationshipMotion.doorFeedback, trigger: privateOpen)
        .task { if relationship == nil { relationship = RelationshipStore() } }
    }

    private var tabs: some View {
        TabView(selection: Binding(get: { destination }, set: { go(to: $0) })) {
            ForEach(Destination.allCases, id: \.self) { destination in
                content(for: destination)
                    .tabEntrance(from: entrance)
                    .toolbarBackground(Room.bar, for: .tabBar)
                    .toolbarBackground(.visible, for: .tabBar)
                    .tabItem { Label(destination.title, systemImage: destination.symbol) }
                    .tag(destination)
            }
        }
        .tint(Room.sage)
    }

    @ViewBuilder private func content(for destination: Destination) -> some View {
        if let relationship {
            switch destination {
            case .home:
                HomeView(store: store, relationship: relationship, open: openChat) { surfaceFrame = $0 }
            case .chat:
                ChatScreen(store: store, partner: relationship.snapshot.profile.partner,
                           focusRequested: $composerFocusRequested, openPrivate: openPrivate) { moonFrame = $0 }
            case .us:
                UsView(store: store, relationship: relationship)
            }
        } else {
            ScreenScaffold { EmptyView() }
        }
    }

    private func go(to new: Destination, glide: Bool = true) {
        entrance = glide && new != destination ? (new.order > destination.order ? 1 : -1) : 0
        destination = new
    }

    /// The Opening: Home's conversation surface rises and becomes Chat. A proxy
    /// surface travels from the surface's frame to the full room, then hands off.
    private func openChat(focusComposer: Bool) {
        composerFocusRequested = focusComposer
        guard destination == .home, !reduceMotion, surfaceFrame.height > 0, roomSize.height > 0 else {
            withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) { go(to: .chat) }
            return
        }
        morphExpanded = false
        morphFrom = surfaceFrame
        // Next tick, so the proxy exists at the surface's frame before it rises.
        Task { @MainActor in
            withAnimation(RelationshipMotion.softHero) {
                morphExpanded = true
            } completion: {
                go(to: .chat, glide: false)
                withAnimation(RelationshipMotion.handoff) { morphFrom = nil }
            }
        }
    }

    private func openPrivate() {
        privateOpen = true
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.halo, reduceMotion: reduceMotion)) {
            privateProgress = 1
        } completion: {
            if privateOpen { privateSettled = true }
        }
    }

    private func closePrivate() {
        privateSettled = false
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.slow, reduceMotion: reduceMotion)) {
            privateProgress = 0
        } completion: {
            if privateProgress == 0 { privateOpen = false }
        }
    }
}

/// Home's surface on its way to becoming Chat: the top edge rises, corners
/// flatten, paper warms to cream, and the header lands where Chat's sits.
private struct OpeningProxy: View {
    let from: CGRect
    let expanded: Bool
    let room: CGSize
    let top: CGFloat
    let partner: Person
    let store: WatchlinkStore

    var body: some View {
        let frame = expanded ? CGRect(origin: .zero, size: room) : from
        let radius: CGFloat = expanded ? 0 : 32
        UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
            .fill(expanded ? Room.cream : Room.paper)
            .overlay(alignment: .topLeading) {
                ConversationHeader(partner: partner, state: store.securityState, connected: store.connectionAvailable)
                    .padding(.top, expanded ? top + 8 : 20)
                    .padding(.leading, expanded ? screenMargin : 16)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }
}

extension Person {
    var name: String { nickname.isEmpty ? displayName : nickname }
    var shownName: String { name.isEmpty ? "Your partner" : name }
    var initial: String { name.prefix(1).uppercased() }
}

/// Security-owned wording (SecurityStatusView) on the notice tone, plus what it
/// means for sending. Pinned light so its contrast never depends on the room.
private struct SecurityNotice: View {
    let store: WatchlinkStore
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SecurityStatusView(state: store.securityState, connected: store.connectionAvailable)
            Text(store.canSend ? "Messages will send when the connection returns."
                               : "Sending is paused until the secure link is ready.")
                .font(.caption)
                .foregroundStyle(Room.noticeInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, screenMargin)
        .padding(.vertical, 10)
        .background(Room.notice.ignoresSafeArea(edges: .top))
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .combine)
    }
}
