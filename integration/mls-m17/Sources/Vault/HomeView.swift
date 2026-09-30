import SwiftUI

/// Calm by default: a greeting, and cards only while something is actually waiting.
struct HomeView: View {
    let store: WatchlinkStore
    let relationship: RelationshipStore
    let openChat: () -> Void

    /// Partner rituals need both a secure link and the (not yet built) sync channel.
    static func partnerActionsEnabled(channelAvailable: Bool, canSend: Bool) -> Bool { channelAvailable && canSend }

    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    var body: some View {
        // Minute ticks let time-locked letters surface without any polling of their own.
        TimelineView(.everyMinute) { context in
            let cards = relationship.homeCards(now: context.date)
            ScrollView {
                VStack(alignment: .leading, spacing: WatchlinkStyle.Space.xxl) {
                    header(at: context.date)
                    if cards.isEmpty {
                        Text("Nothing is waiting. That's okay.")
                            .font(WatchlinkStyle.Typography.secondary)
                            .foregroundStyle(WatchlinkStyle.secondary)
                    } else {
                        VStack(spacing: WatchlinkStyle.Space.m) {
                            ForEach(cards, id: \.self) { card in
                                if let content = HomeCardContent(card, in: relationship.snapshot) {
                                    HomeCardView(content: content) { relationship.resolve(card) }
                                }
                            }
                        }
                    }
                    actions
                }
                .padding(.horizontal, WatchlinkStyle.Space.xl)
                .padding(.vertical, WatchlinkStyle.Space.xxl)
            }
        }
        .background(WatchlinkStyle.background.ignoresSafeArea())
    }

    private func header(at date: Date) -> some View {
        HStack(alignment: .center, spacing: WatchlinkStyle.Space.l) {
            PresenceMark(presence: PartnerPresence.current(for: relationship))
            VStack(alignment: .leading, spacing: WatchlinkStyle.Space.xs) {
                Text(Self.greeting(at: date)).font(WatchlinkStyle.Typography.title)
                Text(partnerLine).font(WatchlinkStyle.Typography.secondary).foregroundStyle(WatchlinkStyle.secondary)
            }
        }
        .padding(.top, WatchlinkStyle.Space.xl)
    }

    private var partnerLine: String {
        let partner = relationship.snapshot.profile.partner
        return partner.initial.isEmpty ? "Your private space" : "You and \(partner.shownName)"
    }

    private var actions: some View {
        let enabled = Self.partnerActionsEnabled(channelAvailable: relationship.channel.isAvailable, canSend: store.canSend)
        return VStack(alignment: .leading, spacing: WatchlinkStyle.Space.m) {
            HStack(spacing: WatchlinkStyle.Space.s) {
                QuietAction(title: "Message", symbol: "bubble.left", action: openChat)
                QuietAction(title: "Footprint", symbol: "hand.wave") {
                    _ = relationship.share(.signal(Signal(kind: .footprint)))
                }
                .disabled(!enabled)
            }
            if !enabled {
                Text("Footprints and shared rituals arrive in a later update.")
                    .font(WatchlinkStyle.Typography.caption)
                    .foregroundStyle(WatchlinkStyle.secondary)
            }
        }
    }
}

/// Presence is only ever shown when it is real. Until partner sync exists it
/// is always `.unknown`, which renders as a still mark with no claim attached.
enum PartnerPresence: Equatable {
    case unknown, together

    // ponytail: always .unknown; becomes real presence once the sync hook delivers it.
    static func current(for relationship: RelationshipStore) -> Self { .unknown }
}

private struct PresenceMark: View {
    let presence: PartnerPresence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            if presence == .together {
                Circle().fill(WatchlinkStyle.tint.opacity(0.18))
                    .scaleEffect(breathing ? 1.18 : 1)
                    .opacity(breathing ? 0.5 : 1)
            }
            WatchlinkMark(size: 44)
        }
        .frame(width: 56, height: 56)
        .onAppear {
            guard presence == .together, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) { breathing = true }
        }
        .accessibilityElement()
        .accessibilityLabel(presence == .together ? "You're both here" : "Watchlink")
    }
}

struct HomeCardContent: Equatable {
    var title: String
    var detail: String
    var symbol: String
    /// nil while the card's feature isn't built yet; the card still waits honestly.
    var actionTitle: String?

    init?(_ card: HomeCard, in snapshot: RelationshipSnapshot) {
        let partner = snapshot.profile.partner.shownName
        switch card {
        case .signal(let id):
            guard let signal = snapshot.signals.first(where: { $0.id == id }) else { return nil }
            switch signal.kind {
            case .footprint:
                self.init(title: "A footprint", detail: "\(partner) was here, thinking of you.", symbol: "hand.wave", actionTitle: "Okay")
            case .stillHere(let kind):
                self.init(title: "Still here", detail: kind.text, symbol: "flag", actionTitle: "Okay")
            }
        case .revealWaiting:
            self.init(title: "Reveal Together", detail: "\(partner) answered. Both answers stay hidden until you answer too.", symbol: "eye.slash")
        case .revealReady:
            self.init(title: "Reveal Together", detail: "Both answers are ready to open together.", symbol: "eye")
        case .decisionWaiting(let id):
            self.init(title: snapshot.decisions.first { $0.id == id }?.title ?? "Blind decision",
                      detail: "Your private vote is waiting.", symbol: "square.stack")
        case .decisionMatched(let id):
            self.init(title: snapshot.decisions.first { $0.id == id }?.title ?? "Blind decision",
                      detail: "You have a match.", symbol: "checkmark.circle")
        case .letterOpenable(let id):
            self.init(title: "A letter can be opened", detail: snapshot.letters.first { $0.id == id }?.label ?? "",
                      symbol: "envelope")
        case .moment:
            self.init(title: "A new Moment", detail: "From \(partner).", symbol: "camera")
        }
    }

    init(title: String, detail: String, symbol: String, actionTitle: String? = nil) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.actionTitle = actionTitle
    }
}

extension RelationshipStore {
    /// Resolving is what removes a card; cards are never stored or dismissed on their own.
    func resolve(_ card: HomeCard) {
        guard case .signal(let id) = card else { return }  // other cards resolve inside their features (Stage 4)
        update { state in
            if let index = state.signals.firstIndex(where: { $0.id == id }) { state.signals[index].acknowledged = true }
        }
    }
}

private struct HomeCardView: View {
    let content: HomeCardContent
    let resolve: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: WatchlinkStyle.Space.m) {
            Image(systemName: content.symbol)
                .font(WatchlinkStyle.Typography.body)
                .foregroundStyle(WatchlinkStyle.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WatchlinkStyle.Space.xs) {
                Text(content.title).font(WatchlinkStyle.Typography.heading)
                Text(content.detail).font(WatchlinkStyle.Typography.secondary).foregroundStyle(WatchlinkStyle.secondary)
                if let actionTitle = content.actionTitle {
                    Button(actionTitle, action: resolve)
                        .font(WatchlinkStyle.Typography.secondary.weight(.semibold))
                        .foregroundStyle(WatchlinkStyle.tint)
                        .padding(.top, WatchlinkStyle.Space.xs)
                }
            }
        }
        .watchlinkSurface()
        .accessibilityElement(children: .contain)
    }
}

private struct QuietAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(WatchlinkStyle.Typography.secondary.weight(.semibold))
                .padding(.horizontal, WatchlinkStyle.Space.l)
                .frame(height: 44)
                .background(WatchlinkStyle.soft, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? WatchlinkStyle.tint : WatchlinkStyle.secondary)
        .opacity(isEnabled ? 1 : 0.6)
    }
}
