import Foundation
import Observation

/// Storage for ordinary relationship metadata only. Private, view-once and
/// media content never reach it (see `RelationshipSnapshot.persistable`).
protocol RelationshipPersistence {
    /// nil when nothing was saved yet. Throws when saved data exists but can't be read.
    func load() throws -> RelationshipSnapshot?
    func save(_ snapshot: RelationshipSnapshot) throws
}

/// One JSON file with complete file protection, in a directory excluded from backup.
/// ponytail: not the final home for sensitive content; that waits for a reviewed encrypted local vault.
struct FileRelationshipPersistence: RelationshipPersistence {
    var directory = URL.applicationSupportDirectory.appending(path: "Watchlink", directoryHint: .isDirectory)
    private var file: URL { directory.appending(path: "relationship.json") }

    func load() throws -> RelationshipSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        return try JSONDecoder().decode(RelationshipSnapshot.self, from: Data(contentsOf: file))
    }

    func save(_ snapshot: RelationshipSnapshot) throws {
        var directory = self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

/// Integration boundary for partner sync. Until the security owner adds a
/// generic application-event hook to WatchlinkStore (docs/RELATIONSHIP_APP.md),
/// only `NoRelationshipChannel` ships. Product code never reaches the engine or
/// the relay directly, and never disguises events as chat messages.
protocol RelationshipChannel: AnyObject {
    var isAvailable: Bool { get }
    func send(_ event: RelationshipEvent) throws
}

final class NoRelationshipChannel: RelationshipChannel {
    let isAvailable = false
    func send(_ event: RelationshipEvent) throws { throw SecurityFailure.unavailable }
}

/// What one device tells the other. Small metadata only: media travels as an
/// encrypted blob reference, never as bytes inside an application message.
enum RelationshipEvent: Codable, Equatable, Sendable {
    case revealAnswer(session: UUID, prompt: String, category: RevealSession.Category, answer: String)
    case decisionVote(decision: UUID, title: String, options: [String], picks: Set<String>)
    case letter(LockedMessage)
    case signal(Signal)
}

/// Relationship state for the product layer. Holds no reference to
/// WatchlinkStore or the engine, so it can't change `canSend` or `SecurityState`,
/// and neither a security reset nor `notPaired` erases it. Deletion will only be
/// an explicit, separate "Delete Relationship Data" action.
@MainActor @Observable
final class RelationshipStore {
    private(set) var snapshot: RelationshipSnapshot
    /// False when saved data exists but couldn't be read (device locked, corrupt,
    /// newer schema). The session then never writes, so that file is never overwritten.
    private(set) var persistenceAvailable: Bool
    private(set) var lastSaveFailed = false
    @ObservationIgnored private let persistence: any RelationshipPersistence
    @ObservationIgnored let channel: any RelationshipChannel

    init(persistence: any RelationshipPersistence = FileRelationshipPersistence(),
         channel: any RelationshipChannel = NoRelationshipChannel()) {
        self.persistence = persistence
        self.channel = channel
        do {
            snapshot = try persistence.load() ?? RelationshipSnapshot()
            persistenceAvailable = true
        } catch {
            snapshot = RelationshipSnapshot()
            persistenceAvailable = false
        }
    }

    func homeCards(now: Date = Date()) -> [HomeCard] { snapshot.homeCards(now: now) }

    /// The single mutation path. Saves only the persistable projection.
    /// ponytail: synchronous main-thread write of one small file; move off-main if it grows.
    func update(_ change: (inout RelationshipSnapshot) -> Void) {
        change(&snapshot)
        guard persistenceAvailable else { return }
        do {
            try persistence.save(snapshot.persistable)
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
        }
    }

    /// Sends to the partner when sync exists. Callers keep the local change either way.
    @discardableResult
    func share(_ event: RelationshipEvent) -> Bool {
        guard channel.isAvailable else { return false }
        return (try? channel.send(event)) != nil
    }

    /// Inbound demux target: authenticated partner events land here. Replays are idempotent.
    func apply(_ event: RelationshipEvent) {
        update { state in
            switch event {
            case let .revealAnswer(id, prompt, category, answer):
                if !state.reveals.contains(where: { $0.id == id }) {
                    state.reveals.append(RevealSession(id: id, prompt: prompt, category: category))
                }
                let index = state.reveals.firstIndex { $0.id == id }!
                state.reveals[index].answer(answer, by: .partner)
            case let .decisionVote(id, title, options, picks):
                if !state.decisions.contains(where: { $0.id == id }) {
                    state.decisions.append(BlindDecision(id: id, title: title, options: options))
                }
                let index = state.decisions.firstIndex { $0.id == id }!
                state.decisions[index].vote(picks, by: .partner)
            case var .letter(letter):
                guard !state.letters.contains(where: { $0.id == letter.id }) else { return }
                letter.from = .partner
                letter.openedAt = nil
                state.letters.append(letter)
            case var .signal(signal):
                guard !state.signals.contains(where: { $0.id == signal.id }) else { return }
                signal.from = .partner
                signal.acknowledged = false
                state.signals.append(signal)
            }
        }
    }
}
