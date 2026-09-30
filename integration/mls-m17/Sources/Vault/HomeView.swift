import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// Layered paper: the greeting sits on the ground, waiting cards (only while
/// something waits) rest on top of the conversation surface, and the surface
/// rises from the bottom of the room as the lower half of Chat.
struct HomeView: View {
    let store: WatchlinkStore
    let relationship: RelationshipStore
    /// Opens Chat; `true` also focuses the composer (the "Write to…" pill).
    let open: (_ focusComposer: Bool) -> Void
    let onSurfaceFrame: (CGRect) -> Void

    /// Presentation-only: a card the store has already resolved, shown confirmed
    /// for a short dwell before it tucks away. The store stays the only truth.
    @State private var confirming: [HomeCard: HomeCardContent] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

    /// "Good evening,\nDeniz." with a name, "Good evening." without one.
    static func headline(at date: Date, name: String, calendar: Calendar = .current) -> String {
        let hello = greeting(at: date, calendar: calendar)
        return name.isEmpty ? "\(hello)." : "\(hello),\n\(name)."
    }

    var body: some View {
        // Minute ticks let time-locked letters surface without any polling of their own.
        TimelineView(.everyMinute) { context in
            let cards = displayedCards(now: context.date)
            ScreenScaffold {
                VStack(alignment: .leading, spacing: 12) {
                    HeadlineBlock(meta: context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                                  headline: Self.headline(at: context.date, name: relationship.snapshot.profile.me.name))
                        .padding(.bottom, 16)
                    ForEach(cards, id: \.card) { item in
                        WaitingCard(content: item.content, confirmed: item.confirmed) { resolve(item.card) }
                            .padding(.horizontal, 14)
                            .zIndex(0)
                            .wlTransition(.tuck, reduceMotion: reduceMotion)
                    }
                    ConversationSurface(store: store, partner: relationship.snapshot.profile.partner,
                                        presence: PartnerPresence.current(for: relationship), open: open)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onSurfaceFrame($0) }
                        // The surface sits above the cards so a resolved card slips behind it.
                        .zIndex(1)
                }
                .animation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion), value: cards.map(\.card))
            }
        }
    }

    private struct DisplayedCard {
        let card: HomeCard
        let content: HomeCardContent
        let confirmed: Bool
    }

    private func displayedCards(now: Date) -> [DisplayedCard] {
        let confirmed = confirming.map { DisplayedCard(card: $0.key, content: $0.value, confirmed: true) }
        let waiting = relationship.homeCards(now: now).compactMap { card in
            HomeCardContent(card, in: relationship.snapshot).map { DisplayedCard(card: card, content: $0, confirmed: false) }
        }
        return confirmed + waiting.filter { confirming[$0.card] == nil }
    }

    /// The Tuck: truth first (the store resolves immediately), then the card
    /// confirms in place, dwells, and slips behind the surface. Never blocks input.
    private func resolve(_ card: HomeCard) {
        guard let content = HomeCardContent(card, in: relationship.snapshot) else { return }
        withAnimation(RelationshipMotion.resolve(RelationshipMotion.slow, reduceMotion: reduceMotion)) {
            confirming[card] = content
            relationship.resolve(card)
        }
        AccessibilityNotification.Announcement("\(content.title) received").post()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 300 : 700))
            withAnimation(RelationshipMotion.resolve(RelationshipMotion.soft, reduceMotion: reduceMotion)) {
                confirming[card] = nil
            }
        }
    }
}

/// The lower half of Chat, resting in the room: who, the trust line, the last
/// few messages (from the store, in memory only) and the way in.
private struct ConversationSurface: View {
    let store: WatchlinkStore
    let partner: Person
    let presence: PartnerPresence
    let open: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Button { open(false) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        ConversationHeader(partner: partner, state: store.securityState,
                                           connected: store.connectionAvailable, presence: presence)
                        Spacer(minLength: 0)
                        if let last = store.messages.last {
                            Text(last.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(Room.ink3)
                        }
                    }
                    Spacer(minLength: 12)
                    if store.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("You and \(partner.shownName) are connected.").wlTitle().foregroundStyle(Room.ink)
                            Text("This is your space now. Messages here are end-to-end encrypted between your two devices.")
                                .font(.subheadline)
                                .foregroundStyle(Room.ink2)
                        }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(MessageRun.group(Array(store.messages.suffix(3)))) { run in
                                MessageRunView(run: run, reduceMotion: true)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    Color.clear.frame(height: 56)  // room for the pill
                }
                .padding(.top, 20)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(Pressable())
            .accessibilityLabel("Open conversation with \(partner.shownName)")

            Button { open(true) } label: {
                Text(store.messages.isEmpty ? "Write the first message" : partner.writeTo)
                    .font(.body)
                    .foregroundStyle(Room.ink3)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .background(Room.cream, in: Capsule())
                    .overlay(Capsule().stroke(Room.ink.opacity(0.06), lineWidth: 1))
            }
            .buttonStyle(Pressable())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32, style: .continuous)
                .fill(Room.paper)
                .shadow(color: Room.ink.opacity(0.10), radius: 20, y: -10)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

/// A card that exists only while something waits. Confirmed = the store has
/// resolved it; it shows that for a moment, then tucks behind the surface.
private struct WaitingCard: View {
    let content: HomeCardContent
    let confirmed: Bool
    let resolve: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: confirmed ? "checkmark" : content.symbol)
                .font(.subheadline)
                .foregroundStyle(Room.sageDeep)
                .frame(width: 30, height: 30)
                .background(confirmed ? Room.paper : Room.mist, in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(confirmed ? "Received" : content.title).font(.subheadline.weight(.semibold))
                if !confirmed {
                    Text(content.detail).font(.subheadline).foregroundStyle(Room.ink2)
                }
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
            if let actionTitle = content.actionTitle, !confirmed {
                Button(actionTitle, action: resolve)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Room.sageDeep)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
            }
        }
        .foregroundStyle(Room.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .wlCard(fill: confirmed ? Room.mist : Room.paper)
        .accessibilityElement(children: .contain)
    }
}

/// Presence is only ever shown when it is real. Until partner sync exists it
/// is always `.unknown`, which draws nothing and claims nothing.
enum PartnerPresence: Equatable {
    case unknown, together

    // ponytail: always .unknown; becomes real presence once the sync hook delivers it.
    static func current(for relationship: RelationshipStore) -> Self { .unknown }
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
