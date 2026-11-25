import Foundation

// Application-layer relationship state. Independent of WatchlinkStore,
// SecurityState and the MLS engine: nothing here can widen what the security
// layer permits, and security resets never erase it.

enum Author: String, Codable, Sendable { case me, partner }

struct Person: Codable, Equatable, Sendable {
    var displayName = ""
    var nickname = ""
    var avatar: LocalMediaRef?
}

enum ThemePreference: String, Codable, CaseIterable, Sendable { case system, light, dark }

struct CoupleProfile: Codable, Equatable, Sendable {
    var me = Person()
    var partner = Person()
    var theme = ThemePreference.system
}

/// Opaque handle to media held by the media layer; never the bytes themselves.
struct LocalMediaRef: Codable, Hashable, Sendable { var id = UUID() }

struct ImportantDate: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case anniversary, birthday, firstDate, custom }
    var id = UUID()
    var kind: Kind
    var label: String
    var date: Date
}

struct JournalEntry: Identifiable, Codable, Equatable, Sendable {
    static let maxWords = 10
    var id = UUID()
    var day: Date
    var text: String

    /// nil when empty or longer than `maxWords`. Optional and streak-free by design.
    init?(text: String, day: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...Self.maxWords).contains(trimmed.split(whereSeparator: \.isWhitespace).count) else { return nil }
        self.text = trimmed
        self.day = day
    }
}

struct JarItem: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var addedBy = Author.me
    var drawnAt: Date?
}

/// Presentation only: every style travels the same secure path.
enum RevealStyle: String, Codable, Sendable { case plain, scratch, viewOnce }

struct Moment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var from = Author.me
    /// One composed front + rear asset.
    var media: LocalMediaRef
    var caption = ""
    var isPrivate = false
    var viewed = false
}

enum UnlockCondition: Codable, Equatable, Sendable {
    /// A date/time. Midnight and "in N hours" resolve to this when written.
    case at(Date)
    /// "Open when you're sad": the recipient decides when.
    case feeling(String)

    static func midnight(after now: Date, calendar: Calendar = .current) -> Self {
        .at(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!)
    }

    static func delay(_ interval: TimeInterval, from now: Date) -> Self { .at(now.addingTimeInterval(interval)) }

    func isOpenable(now: Date) -> Bool {
        if case .at(let date) = self { return now >= date }
        return true
    }
}

/// "Open When" letters.
struct LockedMessage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var from = Author.me
    var label: String
    var body: String
    var media: LocalMediaRef?
    var condition: UnlockCondition
    var style = RevealStyle.plain
    var isPrivate = false
    var createdAt = Date()
    var openedAt: Date?

    /// Sensitive content never enters ordinary persistence (see `RelationshipSnapshot.persistable`).
    var isSensitive: Bool { isPrivate || style == .viewOnce }

    func canOpen(now: Date) -> Bool { openedAt == nil && condition.isOpenable(now: now) }

    @discardableResult
    mutating func open(now: Date) -> Bool {
        guard canOpen(now: now) else { return false }
        openedAt = now
        return true
    }
}

struct RevealSession: Identifiable, Codable, Equatable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable { case edgy, flirty, uncomfortable, absurd, serious }
    var id = UUID()
    var prompt: String
    var category: Category
    private(set) var mine: String?
    private(set) var theirs: String?
    var seen = false

    init(id: UUID = UUID(), prompt: String, category: Category) {
        self.id = id
        self.prompt = prompt
        self.category = category
    }

    var hasAnswered: Bool { mine != nil }
    var partnerHasAnswered: Bool { theirs != nil }

    /// Both answers together, or nothing. Neither answer is ever exposed alone.
    /// ponytail: client-side hiding only; a modified client could read `theirs`
    /// early. A commit-then-reveal exchange needs security review.
    var revealed: (mine: String, theirs: String)? {
        guard let mine, let theirs else { return nil }
        return (mine, theirs)
    }

    /// Answers are final once given.
    mutating func answer(_ text: String, by author: Author) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        switch author {
        case .me where mine == nil: mine = text
        case .partner where theirs == nil: theirs = text
        default: break
        }
    }
}

struct BlindDecision: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var options: [String]
    private(set) var mine: Set<String>?
    private(set) var theirs: Set<String>?
    var seen = false

    init(id: UUID = UUID(), title: String, options: [String]) {
        self.id = id
        self.title = title
        self.options = options
    }

    var hasVoted: Bool { mine != nil }
    var partnerHasVoted: Bool { theirs != nil }

    /// Shared picks only, in option order, once both have voted. A lone vote never shows.
    var matches: [String]? {
        guard let mine, let theirs else { return nil }
        return options.filter { mine.contains($0) && theirs.contains($0) }
    }

    /// Votes are final; picks outside `options` are dropped. An empty vote means "none of these".
    mutating func vote(_ picks: Set<String>, by author: Author) {
        let picks = picks.intersection(options)
        switch author {
        case .me where mine == nil: mine = picks
        case .partner where theirs == nil: theirs = picks
        default: break
        }
    }
}

enum StillHere: String, Codable, CaseIterable, Sendable {
    case upsetButHere, notReadyToTalk, stillLoveYou, openToPeace, closenessNotTalk

    var text: String {
        switch self {
        case .upsetButHere: return "I'm still upset, but I'm here."
        case .notReadyToTalk: return "I'm not ready to talk yet."
        case .stillLoveYou: return "I still love you."
        case .openToPeace: return "I'm open to making peace."
        case .closenessNotTalk: return "I want closeness, but not a conversation yet."
        }
    }
}

/// Intentional, one-off signals. Never generated automatically, never counted.
struct Signal: Identifiable, Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable { case footprint, stillHere(StillHere) }
    var id = UUID()
    var kind: Kind
    var from = Author.me
    var at = Date()
    var acknowledged = false
}

/// Everything the relationship space holds. No counters, scores, streaks or last-seen times.
struct RelationshipSnapshot: Codable, Equatable, Sendable {
    var profile = CoupleProfile()
    var dates: [ImportantDate] = []
    var journal: [JournalEntry] = []
    var jar: [JarItem] = []
    var moments: [Moment] = []
    var letters: [LockedMessage] = []
    var reveals: [RevealSession] = []
    var decisions: [BlindDecision] = []
    var signals: [Signal] = []

    /// What may be written to ordinary protected storage. Private and view-once
    /// content stays in memory only until an encrypted local vault is reviewed.
    var persistable: Self {
        var copy = self
        copy.letters.removeAll { $0.isSensitive }
        copy.moments.removeAll { $0.isPrivate }
        return copy
    }
}

/// Something meaningful is waiting. Derived on every read and never stored, so
/// a resolved action simply stops producing its card.
enum HomeCard: Hashable, Sendable {
    case signal(UUID)
    case revealWaiting(UUID), revealReady(UUID)
    case decisionWaiting(UUID), decisionMatched(UUID)
    case letterOpenable(UUID)
    case moment(UUID)
}

extension RelationshipSnapshot {
    func homeCards(now: Date) -> [HomeCard] {
        var cards: [HomeCard] = []
        for signal in signals where signal.from == .partner && !signal.acknowledged { cards.append(.signal(signal.id)) }
        for reveal in reveals {
            if reveal.revealed != nil {
                if !reveal.seen { cards.append(.revealReady(reveal.id)) }
            } else if reveal.partnerHasAnswered && !reveal.hasAnswered {
                cards.append(.revealWaiting(reveal.id))
            }
        }
        for decision in decisions {
            if decision.matches != nil {
                if !decision.seen { cards.append(.decisionMatched(decision.id)) }
            } else if decision.partnerHasVoted && !decision.hasVoted {
                cards.append(.decisionWaiting(decision.id))
            }
        }
        // Only time locks announce themselves; "open when you're sad" waits quietly in Us.
        for letter in letters where letter.from == .partner && letter.canOpen(now: now) {
            if case .at = letter.condition { cards.append(.letterOpenable(letter.id)) }
        }
        for moment in moments where moment.from == .partner && !moment.viewed { cards.append(.moment(moment.id)) }
        return cards
    }
}
