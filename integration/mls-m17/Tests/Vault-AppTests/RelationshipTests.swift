import XCTest

private final class MemoryPersistence: RelationshipPersistence {
    var saved: RelationshipSnapshot?
    var unreadable = false
    func load() throws -> RelationshipSnapshot? {
        if unreadable { throw CocoaError(.fileReadCorruptFile) }
        return saved
    }
    func save(_ snapshot: RelationshipSnapshot) throws { saved = snapshot }
}

@MainActor
final class RelationshipTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testResetSecurityAndNotPairedKeepRelationshipData() {
        let persistence = MemoryPersistence()
        let relationship = RelationshipStore(persistence: persistence)
        relationship.update {
            $0.profile.partner.nickname = "E"
            $0.journal.append(JournalEntry(text: "Rain on the window, tea, you.")!)
            $0.jar.append(JarItem(text: "Night swim"))
            $0.dates.append(ImportantDate(kind: .anniversary, label: "Us", date: now))
            $0.moments.append(Moment(media: LocalMediaRef()))
        }
        let expected = relationship.snapshot

        let security = WatchlinkStore(securityState: .notPaired)
        security.resetSecurity()

        XCTAssertEqual(relationship.snapshot, expected)
        XCTAssertEqual(RelationshipStore(persistence: persistence).snapshot, expected)
    }

    func testRelationshipStateNeverChangesSecurity() {
        let security = WatchlinkStore()
        let state = security.securityState, canSend = security.canSend
        let relationship = RelationshipStore(persistence: MemoryPersistence())
        relationship.apply(.signal(Signal(kind: .footprint)))
        relationship.apply(.revealAnswer(session: UUID(), prompt: "?", category: .absurd, answer: "yes"))
        relationship.update { $0.jar.append(JarItem(text: "Picnic")) }
        XCTAssertFalse(relationship.share(.signal(Signal(kind: .footprint))))
        XCTAssertEqual(security.securityState, state)
        XCTAssertEqual(security.canSend, canSend)
    }

    func testHomeCardsAreDerivedAndDisappearWhenResolved() throws {
        let relationship = RelationshipStore(persistence: MemoryPersistence())
        let signal = Signal(kind: .stillHere(.notReadyToTalk))
        relationship.apply(.signal(signal))
        XCTAssertEqual(relationship.homeCards(now: now), [.signal(signal.id)])

        relationship.update { $0.signals[0].acknowledged = true }
        XCTAssertEqual(relationship.homeCards(now: now), [])

        // Cards are not part of what is stored.
        let json = String(decoding: try JSONEncoder().encode(relationship.snapshot), as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("card"))
    }

    func testRevealStaysHiddenUntilBothAnswer() {
        let relationship = RelationshipStore(persistence: MemoryPersistence())
        let id = UUID()
        relationship.apply(.revealAnswer(session: id, prompt: "Worst date?", category: .uncomfortable, answer: "Mine"))
        XCTAssertNil(relationship.snapshot.reveals[0].revealed)
        XCTAssertEqual(relationship.homeCards(now: now), [.revealWaiting(id)])

        relationship.update { $0.reveals[0].answer("Also mine", by: .me) }
        XCTAssertEqual(relationship.snapshot.reveals[0].revealed?.theirs, "Mine")
        XCTAssertEqual(relationship.homeCards(now: now), [.revealReady(id)])

        // Answers are final; a replayed event changes nothing.
        relationship.apply(.revealAnswer(session: id, prompt: "Worst date?", category: .uncomfortable, answer: "Edited"))
        XCTAssertEqual(relationship.snapshot.reveals[0].revealed?.theirs, "Mine")

        relationship.update { $0.reveals[0].seen = true }
        XCTAssertEqual(relationship.homeCards(now: now), [])
    }

    func testBlindDecisionExposesOnlyIntersection() {
        var decision = BlindDecision(title: "Tonight", options: ["Ramen", "Pizza", "Tacos"])
        decision.vote(["Ramen", "Tacos", "Not an option"], by: .me)
        XCTAssertNil(decision.matches)
        decision.vote(["Tacos", "Pizza"], by: .partner)
        XCTAssertEqual(decision.matches, ["Tacos"])
        decision.vote(["Pizza"], by: .me)
        XCTAssertEqual(decision.matches, ["Tacos"])
    }

    func testJournalWordLimit() {
        XCTAssertNotNil(JournalEntry(text: "one two three four five six seven eight nine ten"))
        XCTAssertNil(JournalEntry(text: "one two three four five six seven eight nine ten eleven"))
        XCTAssertNil(JournalEntry(text: "   "))
    }

    func testLockedMessageTimeConditions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let midnight = UnlockCondition.midnight(after: now, calendar: calendar)
        XCTAssertFalse(midnight.isOpenable(now: now))
        XCTAssertTrue(midnight.isOpenable(now: calendar.startOfDay(for: now).addingTimeInterval(86_400)))

        let delay = UnlockCondition.delay(3_600, from: now)
        XCTAssertFalse(delay.isOpenable(now: now.addingTimeInterval(3_599)))
        XCTAssertTrue(delay.isOpenable(now: now.addingTimeInterval(3_600)))
        XCTAssertTrue(UnlockCondition.feeling("sad").isOpenable(now: now))

        var letter = LockedMessage(label: "Open later", body: "Hi", condition: delay)
        XCTAssertFalse(letter.open(now: now))
        XCTAssertTrue(letter.open(now: now.addingTimeInterval(3_600)))
        XCTAssertFalse(letter.open(now: now.addingTimeInterval(7_200)))
    }

    func testPrivateContentNeverEntersPersistence() {
        let persistence = MemoryPersistence()
        let relationship = RelationshipStore(persistence: persistence)
        let ordinary = LockedMessage(label: "Open when sad", body: "ordinary", condition: .feeling("sad"))
        relationship.update {
            $0.letters += [ordinary,
                           LockedMessage(label: "p", body: "private", condition: .feeling("x"), isPrivate: true),
                           LockedMessage(label: "v", body: "view once", condition: .feeling("x"), style: .viewOnce)]
            $0.moments += [Moment(media: LocalMediaRef(), isPrivate: true)]
        }
        XCTAssertEqual(relationship.snapshot.letters.count, 3)
        XCTAssertEqual(persistence.saved?.letters, [ordinary])
        XCTAssertEqual(persistence.saved?.moments, [])
    }

    func testUnreadableDataIsNeverOverwritten() {
        let persistence = MemoryPersistence()
        persistence.unreadable = true
        let relationship = RelationshipStore(persistence: persistence)
        relationship.update { $0.jar.append(JarItem(text: "x")) }
        XCTAssertFalse(relationship.persistenceAvailable)
        XCTAssertNil(persistence.saved)
    }

    func testFilePersistenceRoundTripsAndIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileRelationshipPersistence(directory: directory)
        XCTAssertNil(try persistence.load())

        var snapshot = RelationshipSnapshot()
        snapshot.jar.append(JarItem(text: "Sunrise walk"))
        try persistence.save(snapshot)
        XCTAssertEqual(try persistence.load(), snapshot)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
}
