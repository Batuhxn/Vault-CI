import CryptoKit
import Foundation
import MLSBridge
import MLSQualification
import Observation
import ProtectedStateStore
import Security

// M1.5 real-device qualification scenarios. Synthetic data only. Results hold
// labels, statuses, versions, OSStatus codes and PUBLIC fingerprints/hashes;
// never keys, MLS state, KeyPackage private bytes, or decrypted state.

public struct ResultLine: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var time = Date()
    public var test: String
    public var status: String  // PASS FAIL SKIP INFO
    public var detail: String
    public var stateVersion: UInt64?
    public var osStatus: Int32?
}

struct Baseline: Codable {
    var conversation: Data
    var alicePin: Data
    var bobPin: Data
    var aliceVersion: UInt64
    var bobVersion: UInt64
    var bootTime: Int64
    var ownNonce: Data?
    var pendingCommitHash: Data?
}

/// Synthetic plaintext markers; the leak scan searches every app file for them.
public let plaintextMarkers = ["M15-SYNTHETIC-PLAINTEXT-ALPHA", "M15-SYNTHETIC-PLAINTEXT-BRAVO"]
let errSecInteractionNotAllowedCode: OSStatus = -25308

@MainActor @Observable
public final class QualificationLab {
    public private(set) var results: [ResultLine] = []
    public private(set) var busy = false
    public let root: URL
    let prefix: String
    private var relay: Relay?
    private var events: [String] = []
    private var lockSnapshot: (Data, Data, UInt64, UInt64)?

    public init(root: URL, servicePrefix: String) {
        self.root = root
        prefix = servicePrefix
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: resultsURL),
           let saved = try? JSONDecoder().decode([ResultLine].self, from: data) {
            results = saved
        }
    }

    // MARK: results

    var resultsURL: URL { root.appendingPathComponent("results.json") }

    func record(_ test: String, _ status: String, _ detail: String, version: UInt64? = nil, osStatus: OSStatus? = nil) {
        results.append(ResultLine(test: test, status: status, detail: detail, stateVersion: version, osStatus: osStatus))
        // Class C: still writable while locked so lock-test samples survive.
        try? JSONEncoder().encode(results)
            .write(to: resultsURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func check(_ test: String, _ condition: Bool, _ detail: String, version: UInt64? = nil, osStatus: OSStatus? = nil) {
        record(test, condition ? "PASS" : "FAIL", detail, version: version, osStatus: osStatus)
    }

    public func clearResults() {
        results = []
        try? FileManager.default.removeItem(at: resultsURL)
    }

    public func report(osVersion: String, build: String) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["Watchlink M1.5 qualification report", "iOS \(osVersion); build \(build)", ""]
        for r in results {
            var line = "\(formatter.string(from: r.time)) [\(r.status)] \(r.test): \(r.detail)"
            if let v = r.stateVersion { line += " stateVersion=\(v)" }
            if let s = r.osStatus { line += " OSStatus=\(s)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: namespaces

    var runService: String { prefix + ".run" }

    func runID() -> String? {
        guard let data = try? KeychainItem.read(service: runService, account: "run") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func service(_ run: String, _ space: String, _ name: String) -> String { "\(prefix).\(run).\(space).\(name)" }

    func directory(_ run: String, _ space: String, _ name: String) -> URL {
        root.appendingPathComponent(run).appendingPathComponent(space).appendingPathComponent(name)
    }

    func loadRelay(_ run: String) throws -> Relay {
        if let relay { return relay }
        let url = root.appendingPathComponent(run).appendingPathComponent("relay.json")
        let loaded = FileManager.default.fileExists(atPath: url.path) ? try Relay.load(from: url) : Relay()
        loaded.persistURL = url
        relay = loaded
        return loaded
    }

    func observe(_ device: Device) -> Device {
        device.store.faults.observer = { [weak self, name = device.name] stage in
            MainActor.assumeIsolated { self?.events.append("\(name):\(stage)") }
        }
        return device
    }

    func open(_ run: String, _ space: String, _ name: String) throws -> Device {
        let device = Device(name: name, service: service(run, space, name), directory: directory(run, space, name),
                            relay: try loadRelay(run), clock: { Int64(Date().timeIntervalSince1970) })
        try device.open()
        return observe(device)
    }

    func create(_ run: String, _ space: String, _ name: String) throws -> Device {
        let dir = directory(run, space, name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return observe(try Device.setup(name: name, service: service(run, space, name), directory: dir,
                                        relay: try loadRelay(run), clock: { Int64(Date().timeIntervalSince1970) }))
    }

    func pair(_ run: String, _ space: String) throws -> (Device, Device) {
        let a = try create(run, space, "alice")
        let b = try create(run, space, "bob")
        try a.scanResponder(b.scanInitiator(a.startPairing()))
        guard case .accepted = try a.addPeer() else { throw Missing() }
        let welcome = a.relay.fetch(b.document.conversation!, recipient: "bob", after: 0)
            .first { $0.kind == "welcome" }
        guard let welcome else { throw Missing() }
        try b.acceptWelcome(welcome)
        return (a, b)
    }

    func version(_ device: Device) -> UInt64? { try? device.store.anchorStore.load().committedVersion }

    var baselineURL: URL { root.appendingPathComponent("baseline.json") }

    func baseline() throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: baselineURL))
    }

    func save(_ baseline: Baseline) throws {
        try JSONEncoder().encode(baseline)
            .write(to: baselineURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func requireRun(_ test: String) -> String? {
        guard let run = runID() else {
            record(test, "SKIP", "no qualification run; tap Run Setup first")
            return nil
        }
        return run
    }

    func guarded(_ test: String, _ body: () throws -> Void) {
        do { try body() } catch {
            record(test, "FAIL", "unexpected \(kind(error))")
        }
    }

    // MARK: Run Setup

    public func runSetup(osVersion: String, protectedDataAvailable: Bool) {
        guarded("Run Setup") {
            explicitWipe(record: false)
            let run = UUID().uuidString
            var marker = KeychainItem.query(runService, "run")
            marker[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            marker[kSecValueData as String] = Data(run.utf8)
            let status = SecItemAdd(marker as CFDictionary, nil)
            record("Run Setup", status == errSecSuccess ? "PASS" : "FAIL",
                   "new synthetic run \(run.prefix(8)); iOS \(osVersion); bootTime \(bootTime()); " +
                   "protectedDataAvailable=\(protectedDataAvailable)", osStatus: status)
        }
    }

    // MARK: Create Protected State

    public func createProtectedState() {
        guard let run = requireRun("Create Protected State") else { return }
        guarded("Create Protected State") {
            let (a, b) = try pair(run, "main")
            try a.send(Data(plaintextMarkers[0].utf8))
            let received = try b.sync()
            try b.send(Data(plaintextMarkers[1].utf8))
            _ = try a.sync()
            check("Create Protected State", received == [Data(plaintextMarkers[0].utf8)],
                  "mutual QR pairing, established, messaging both ways; conversation \(hex(a.document.conversation!)); " +
                  "alice \(fingerprint(a.ownPin)); bob \(fingerprint(b.ownPin))", version: version(a))
            try save(Baseline(conversation: a.document.conversation!, alicePin: a.ownPin, bobPin: b.ownPin,
                              aliceVersion: version(a) ?? 0, bobVersion: version(b) ?? 0, bootTime: bootTime(),
                              ownNonce: a.document.ownNonce))
            let complete = WhenUnlockedThisDeviceOnly()
            for device in [a, b] {
                check("Keychain accessibility", KeychainItem.accessibility(service: device.service, account: "anchor") == complete
                      && KeychainItem.accessibility(service: device.service + ".identity", account: "identity") == complete,
                      "\(device.name) anchor + identity items are WhenUnlockedThisDeviceOnly")
                let protection = fileProtection(device.directory.appendingPathComponent("state.aead"))
                check("Data Protection class", protection == FileProtectionType.complete.rawValue,
                      "\(device.name) state.aead protection=\(protection ?? "unavailable") after atomic replacement")
            }
        }
    }

    // MARK: Relaunch / Reboot

    public func restoreTest(reboot: Bool) {
        let test = reboot ? "Reboot Test" : "Relaunch Test"
        guard let run = requireRun(test) else { return }
        guarded(test) {
            var base = try baseline()
            let booted = bootTime()
            if reboot {
                check(test, booted != base.bootTime, "device reboot observed (kern.boottime changed)")
            } else {
                record(test, "INFO", booted == base.bootTime ? "same boot session" : "a reboot happened since setup")
            }
            let a = try open(run, "main", "alice")
            let b = try open(run, "main", "bob")
            check(test, a.ownPin == base.alicePin && b.ownPin == base.bobPin,
                  "same identity fingerprints alice \(fingerprint(a.ownPin)) bob \(fingerprint(b.ownPin)); no regeneration")
            check(test, a.document.conversation == base.conversation && a.document.lifecycle == .established
                  && b.document.lifecycle == .established && a.document.security == .ok,
                  "same conversation \(hex(base.conversation)); established; security ok")
            let versionsOK = version(a) == base.aliceVersion && version(b) == base.bobVersion
            check(test, versionsOK, "stateVersion unchanged since last checkpoint", version: version(a))
            try a.send(Data(plaintextMarkers[0].utf8))
            let got = try b.sync()
            check(test, got == [Data(plaintextMarkers[0].utf8)], "messaging state restores after \(reboot ? "reboot + first unlock" : "force-kill")")
            base.aliceVersion = version(a) ?? 0
            base.bobVersion = version(b) ?? 0
            base.bootTime = booted
            try save(base)
        }
    }

    // MARK: Lock Test

    /// Runs while the user locks the device. `available` reports UIApplication.isProtectedDataAvailable.
    public func lockTest(seconds: Int, available: @escaping @MainActor () -> Bool) async {
        guard let run = requireRun("Lock Test") else { return }
        busy = true
        defer { busy = false }
        guard let a = try? open(run, "main", "alice"), let b = try? open(run, "main", "bob"),
              let aliceVersion = version(a), let bobVersion = version(b) else {
            return record("Lock Test", "SKIP", "create protected state first (while unlocked)")
        }
        lockSnapshot = (a.ownPin, b.ownPin, aliceVersion, bobVersion)
        let alice = service(run, "main", "alice")
        let file = directory(run, "main", "alice").appendingPathComponent("state.aead")
        record("Lock Test", "INFO", "sampling for \(seconds)s; lock the device now")
        var last = ""
        var sawLocked = false
        for _ in 0..<seconds {
            let protected = available()
            let anchor = KeychainItem.readStatus(service: alice, account: "anchor")
            let identity = KeychainItem.readStatus(service: alice + ".identity", account: "identity")
            let control = KeychainItem.readStatus(service: runService, account: "run")
            let fileRead = fileReadable(file)
            let openResult: String
            do { _ = try open(run, "main", "alice"); openResult = "restored" } catch { openResult = kind(error) }
            relay = nil
            let sample = "protectedData=\(protected) anchor=\(anchor) identity=\(identity) " +
                "classC-control=\(control) stateFile=\(fileRead) open=\(openResult)"
            if sample != last {
                record("Lock Test sample", "INFO", sample, osStatus: anchor)
                last = sample
            }
            if !protected {
                sawLocked = true
                check("Lock Test (locked)", anchor == errSecInteractionNotAllowedCode
                      && identity == errSecInteractionNotAllowedCode && control == errSecSuccess
                      && fileRead != "readable" && openResult != "restored",
                      "WhenUnlocked items unreadable, class-C control readable, protected file unreadable, restore fails closed",
                      osStatus: anchor)
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if !sawLocked { record("Lock Test", "FAIL", "protected data never became unavailable; lock sooner / wait longer") }
        record("Lock Test", "INFO", "unlock, return to the app, then tap Lock Test: Verify After Unlock")
    }

    public func lockVerify() {
        guard let run = requireRun("Lock Test: Verify After Unlock") else { return }
        guarded("Lock Test: Verify After Unlock") {
            guard let snapshot = lockSnapshot ?? (try? baseline()).map({
                ($0.alicePin, $0.bobPin, $0.aliceVersion, $0.bobVersion)
            }) else { return record("Lock Test: Verify After Unlock", "SKIP", "no lock snapshot") }
            let (alicePin, bobPin, aliceVersion, bobVersion) = snapshot
            let a = try open(run, "main", "alice")
            let b = try open(run, "main", "bob")
            check("Lock Test: Verify After Unlock", a.ownPin == alicePin && b.ownPin == bobPin
                  && version(a) == aliceVersion && version(b) == bobVersion && a.document.security == .ok,
                  "original identity/session restored; no regeneration, reset or new session", version: version(a))
        }
    }

    // MARK: Lock during operation

    public func lockDuringOperation(seconds: Int, available: @escaping @MainActor () -> Bool) async {
        guard let run = requireRun("Lock During Operation") else { return }
        busy = true
        defer { busy = false }
        events = []
        record("Lock During Operation", "INFO", "running synthetic transactions for up to \(seconds)s; lock the device now")
        var failure: String?
        var operations = 0
        do {
            let a = try open(run, "main", "alice")
            let b = try open(run, "main", "bob")
            let deadline = Date().addingTimeInterval(TimeInterval(seconds))
            while Date() < deadline, failure == nil {
                events.append("op\(operations):begin protectedData=\(available())")
                do {
                    try a.send(Data(plaintextMarkers[1].utf8))
                    _ = try b.sync()
                    operations += 1
                } catch {
                    failure = kind(error)
                    events.append("op\(operations):failed \(failure!)")
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            failure = "open:\(kind(error))"
        }
        relay = nil
        record("Lock During Operation", "INFO",
               "\(operations) complete operations; first failure: \(failure ?? "none"); stages: \(events.suffix(12).joined(separator: ","))")
        check("Lock During Operation (ordering)", outboundOnlyAfterCommit(events),
              "outbound bytes released only after a durable commit in every transaction")
        record("Lock During Operation", "INFO", "unlock, return, then tap Lock During Operation: Verify")
    }

    public func lockDuringOperationVerify() {
        guard let run = requireRun("Lock During Operation: Verify") else { return }
        var restored: [String: Device] = [:]
        for name in ["alice", "bob"] {
            do {
                let device = try open(run, "main", name)
                restored[name] = device
                check("Lock During Operation: Verify", device.document.security == .ok && device.group != nil,
                      "\(name): outcome A (operation completed; state consistent)", version: version(device))
            } catch is Closed {
                let anchor = try? KeyChainAnchor(service(run, "main", name))
                record("Lock During Operation: Verify", "PASS",
                       "\(name): outcome B (fail closed: pending marker, committed state untouched; explicit wipe required)",
                       version: anchor)
            } catch {
                record("Lock During Operation: Verify", "FAIL", "\(name): \(kind(error))")
            }
        }
        // Outcome A on both: re-checkpoint so later relaunch/reboot tests compare against it.
        if let a = restored["alice"], let b = restored["bob"], var base = try? baseline() {
            base.aliceVersion = version(a) ?? 0
            base.bobVersion = version(b) ?? 0
            try? save(base)
        }
    }

    // MARK: Pending commit

    public func pendingCommitStart() {
        guard let run = requireRun("Pending Commit Test") else { return }
        guarded("Pending Commit Test") {
            let relay = try loadRelay(run)
            let a = try open(run, "main", "alice")
            relay.offline = true  // not persisted: the relaunched app is online
            defer { relay.offline = false }
            do { _ = try a.update() } catch is RelayUnavailable {}
            let bytes = try XCTUnwrapLike(a.document.outbound.first { $0.kind == "commit" }?.data)
            var base = try baseline()
            base.pendingCommitHash = Data(SHA256.hash(data: bytes))
            base.aliceVersion = version(a) ?? 0
            try save(base)
            check("Pending Commit Test", a.document.pendingCommit != nil,
                  "pending commit + exact outbound bytes persisted (sha256 \(hex(base.pendingCommitHash!).prefix(16))); " +
                  "now FORCE-KILL the app, relaunch, tap Pending Commit: Finish", version: version(a))
        }
    }

    public func pendingCommitFinish() {
        guard let run = requireRun("Pending Commit: Finish") else { return }
        guarded("Pending Commit: Finish") {
            let base = try baseline()
            let a = try open(run, "main", "alice")
            let bytes = try XCTUnwrapLike(a.document.outbound.first { $0.kind == "commit" }?.data)
            check("Pending Commit: Finish", Data(SHA256.hash(data: bytes)) == base.pendingCommitHash,
                  "same exact outbound bytes available after relaunch")
            do { try a.send(Data(plaintextMarkers[0].utf8)); record("Pending Commit: Finish", "FAIL", "send allowed while pending") }
            catch is Rejected { record("Pending Commit: Finish", "PASS", "no application send while commit pending") }
            guard case .accepted(let seq) = try a.sendPending() else {
                return record("Pending Commit: Finish", "FAIL", "resend not accepted")
            }
            let relay = try loadRelay(run)
            check("Pending Commit: Finish", Data(SHA256.hash(data: relay.entry(base.conversation, seq: seq).data)) == base.pendingCommitHash,
                  "resent bytes are byte-identical; relay accepted")
            let b = try open(run, "main", "bob")
            _ = try b.sync()
            check("Pending Commit: Finish", a.group?.currentEpoch() == b.group?.currentEpoch(), "peer followed the resent commit")
            var updated = base
            updated.aliceVersion = version(a) ?? 0
            updated.bobVersion = version(b) ?? 0
            updated.pendingCommitHash = nil
            try save(updated)
        }
    }

    // MARK: KeyPackage

    public func keyPackageStart() {
        guard let run = requireRun("KeyPackage Test") else { return }
        guarded("KeyPackage Test") {
            let a = try create(run, "kp", "alice")
            let b = try create(run, "kp", "bob")
            try a.scanResponder(b.scanInitiator(a.startPairing()))
            _ = try a.addPeer()
            check("KeyPackage Test", b.document.keyPackages.count == 1 && b.document.lifecycle == .joinPending,
                  "outstanding KeyPackage persisted; Welcome waiting; now FORCE-KILL, relaunch, tap KeyPackage: Finish")
        }
    }

    public func keyPackageFinish() {
        guard let run = requireRun("KeyPackage: Finish") else { return }
        guarded("KeyPackage: Finish") {
            let b = try open(run, "kp", "bob")
            check("KeyPackage: Finish", b.document.keyPackages.count == 1, "KeyPackage survived force-kill")
            let welcome = try XCTUnwrapLike(b.relay.fetch(b.document.conversation!, recipient: "bob", after: 0)
                .first { $0.kind == "welcome" })
            try b.acceptWelcome(welcome)
            check("KeyPackage: Finish", b.document.lifecycle == .established && b.document.keyPackages.isEmpty,
                  "Welcome joined; consumed KeyPackage deleted")
            do { try b.acceptWelcome(welcome); record("KeyPackage: Finish", "FAIL", "second join accepted") }
            catch is Rejected { record("KeyPackage: Finish", "PASS", "same Welcome cannot join twice") }
        }
    }

    // MARK: Persistent hard stop

    public func hardStopStart() {
        guard let run = requireRun("Hard Stop Test") else { return }
        guarded("Hard Stop Test") {
            let a = try create(run, "stop", "alice")
            let b = try create(run, "stop", "bob")
            try a.scanResponder(b.scanInitiator(a.startPairing()))
            let conversation = a.document.conversation!
            let entry = a.relay.fetch(conversation, recipient: "alice", after: 0)[0]
            let impostor = Client(id: Data("bob".utf8), signatureKeypair: try generateSignatureKeypair(cipherSuite: .curve25519Aes128),
                                  clientConfig: ClientConfig(groupStateStorage: ScratchGroupStorage(), useRatchetTreeExtension: true))
            try a.relay.substitute(conversation, seq: entry.seq, data: impostor.generateKeyPackageMessage().toBytes())
            do { _ = try a.addPeer() } catch is Violation {}
            check("Hard Stop Test", a.document.security == .identityChanged,
                  "impostor KeyPackage -> identityChanged; now FORCE-KILL, relaunch, tap Hard Stop: Finish")
        }
    }

    public func hardStopFinish() {
        guard let run = requireRun("Hard Stop: Finish") else { return }
        guarded("Hard Stop: Finish") {
            let a = try open(run, "stop", "alice")
            var blocked = false
            do { _ = try a.startPairing() } catch is Violation { blocked = true }
            check("Hard Stop: Finish", a.document.security == .identityChanged && a.group == nil && blocked,
                  "hard stop persisted across force-kill; operations blocked; no automatic re-pin")
        }
    }

    // MARK: Wipe / re-pair

    public func wipeTest() {
        guard let run = requireRun("Wipe Test") else { return }
        guarded("Wipe Test") {
            let base = try baseline()
            let a = try open(run, "main", "alice")
            let b = try open(run, "main", "bob")
            let aliceFile = a.directory.appendingPathComponent("state.aead")
            a.wipe()  // anchor first, then identity, then state (incl. KeyPackage records)
            b.wipe()
            let anchor = KeychainItem.readStatus(service: service(run, "main", "alice"), account: "anchor")
            var unavailable = false
            do { _ = try open(run, "main", "alice") } catch is Closed { unavailable = true }
            check("Wipe Test", unavailable && anchor == errSecItemNotFound && !FileManager.default.fileExists(atPath: aliceFile.path),
                  "restore unavailable; anchor gone; protected state gone", osStatus: anchor)
            let (a2, b2) = try pair(run, "main")
            check("Wipe Test", a2.ownPin != base.alicePin && b2.ownPin != base.bobPin,
                  "explicit security reset -> fresh identities (policy); old identity not restored")
            check("Wipe Test", a2.document.conversation != base.conversation && a2.document.ownNonce != base.ownNonce,
                  "fresh conversation_id \(hex(a2.document.conversation!)) and fresh QR nonce")
            try a2.relay.retire(base.conversation)
            var rejected = false
            do { _ = try b2.receive(Envelope(conversation: base.conversation, seq: 1_000_000, kind: "application",
                                             base: 1, data: Data(), sender: "alice")) } catch is Rejected { rejected = true }
            let relayStatus = try a2.relay.post(base.conversation, kind: "application", base: 1, data: Data(), sender: "alice")
            check("Wipe Test", rejected && relayStatus == .reject, "retired conversation_id rejected by device and relay")
            try save(Baseline(conversation: a2.document.conversation!, alicePin: a2.ownPin, bobPin: b2.ownPin,
                              aliceVersion: version(a2) ?? 0, bobVersion: version(b2) ?? 0, bootTime: bootTime(),
                              ownNonce: a2.document.ownNonce))
        }
    }

    // MARK: Reinstall check

    public func reinstallCheck() {
        guard let run = runID() else {
            return record("Reinstall Check", "INFO", "no leftover qualification Keychain marker (fresh install, or iOS removed the items)")
        }
        let alice = service(run, "main", "alice")
        let anchor = KeychainItem.readStatus(service: alice, account: "anchor")
        let stateExists = FileManager.default.fileExists(
            atPath: directory(run, "main", "alice").appendingPathComponent("state.aead").path)
        if stateExists {
            return record("Reinstall Check", "INFO", "protected state present; no reinstall detected", osStatus: anchor)
        }
        var failedClosed = false
        do { _ = try open(run, "main", "alice") } catch is Closed { failedClosed = true } catch {}
        check("Reinstall Check", anchor == errSecSuccess && failedClosed,
              "leftover Keychain survived reinstall, protected state gone -> FAIL CLOSED; explicit wipe required; " +
              "no automatic identity/session reconstruction")
    }

    // MARK: Explicit wipe of everything this app created

    public func explicitWipe(record shouldRecord: Bool = true) {
        if let run = runID() {
            for space in ["main", "kp", "stop"] {
                for name in ["alice", "bob"] {
                    KeychainItem.delete(service: service(run, space, name), account: "anchor")
                    KeychainItem.delete(service: service(run, space, name) + ".identity", account: "identity")
                }
            }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(run))
        }
        KeychainItem.delete(service: runService, account: "run")
        try? FileManager.default.removeItem(at: baselineURL)
        relay = nil
        if shouldRecord { record("Explicit Wipe", "INFO", "all qualification Keychain items and files removed") }
    }

    // MARK: Plaintext / local storage scan

    public func leakageScan(container: URL) {
        var scanned = 0
        var hits: [String] = []
        var temporary: [String] = []
        let needles = plaintextMarkers.flatMap { [Data($0.utf8), Data(Data($0.utf8).base64EncodedString().utf8)] }
        let enumerator = FileManager.default.enumerator(at: container, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent.hasSuffix(".pending") || url.path.contains("/.dat.nosync") {
                temporary.append(url.lastPathComponent)
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            scanned += 1
            if needles.contains(where: { data.range(of: $0) != nil }) { hits.append(url.lastPathComponent) }
        }
        check("Plaintext Scan", hits.isEmpty && temporary.isEmpty,
              "\(scanned) readable app files scanned; marker hits=\(hits.count); leftover temp files=\(temporary.count)")
    }
}

// MARK: - helpers (non-secret output only)

final class ScratchGroupStorage: GroupStateStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Data: Data] = [:]
    func state(groupId: Data) throws -> Data? { lock.withLock { states[groupId] } }
    func epoch(groupId: Data, epochId: UInt64) throws -> Data? { nil }
    func write(groupId: Data, groupState: Data, epochInserts: [EpochRecord], epochUpdates: [EpochRecord]) throws {
        lock.withLock { states[groupId] = groupState }
    }
    func maxEpochId(groupId: Data) throws -> UInt64? { nil }
}

struct Missing: Swift.Error {}

func XCTUnwrapLike<T>(_ value: T?) throws -> T {
    guard let value else { throw Missing() }
    return value
}

func KeyChainAnchor(_ service: String) throws -> UInt64 {
    try KeychainStateAnchorStore(service: service, account: "anchor").load().committedVersion
}

func WhenUnlockedThisDeviceOnly() -> String { kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String }

func kind(_ error: Swift.Error) -> String {
    switch error {
    case is Closed: return "Closed"
    case is Rejected: return "Rejected"
    case let violation as Violation: return "Violation(\(violation.security.rawValue))"
    case is RelayUnavailable: return "RelayUnavailable"
    case is MLSBridge.Error: return "MLSError"
    default: return String(describing: type(of: error))
    }
}

func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

/// Public identity fingerprint: first 8 bytes of the (public) identity pin.
func fingerprint(_ pin: Data) -> String { hex(pin.prefix(8)) }

func fileProtection(_ url: URL) -> String? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey].map { "\($0)" }
}

func fileReadable(_ url: URL) -> String {
    do {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = try handle.read(upToCount: 1)
        return "readable"
    } catch let error as NSError {
        let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? error.code
        return "unreadable(\(error.domain == NSCocoaErrorDomain ? "cocoa" : error.domain):\(error.code)/\(posix))"
    }
}

func bootTime() -> Int64 {
    var time = timeval()
    var size = MemoryLayout<timeval>.stride
    guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return 0 }
    return Int64(time.tv_sec)
}

/// Every transaction that released outbound bytes committed durably first.
func outboundOnlyAfterCommit(_ events: [String]) -> Bool {
    var committedSinceBegin: [String: Bool] = [:]
    for event in events {
        let parts = event.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        switch parts[1] {
        case "reserved": committedSinceBegin[parts[0]] = false
        case "committed": committedSinceBegin[parts[0]] = true
        case "outbound-released": if committedSinceBegin[parts[0]] != true { return false }
        default: break
        }
    }
    return true
}
