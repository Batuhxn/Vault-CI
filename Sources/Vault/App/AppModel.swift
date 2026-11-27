import Foundation
import Observation

/// Top-level flow: sign in -> pair -> the relationship shell.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case signedOut
        case unpaired
        /// This device created a pair and shows `code` until the partner joins.
        case waitingForPartner(code: String, pairID: String)
        case paired(PairInfo)
    }

    private(set) var phase: Phase = .loading
    /// The conversation for the current pair, kept across re-renders.
    private(set) var store: WatchlinkStore?
    var errorMessage: String?
    var busy = false
    /// The name typed on the pair screen, saved to the pair once it is complete.
    var myName = ""

    let backend: any ChatBackend
    @ObservationIgnored private var pairListener: (any ListenerToken)?

    init(backend: any ChatBackend) { self.backend = backend }

    var myID: String? { backend.currentUserID }

    func start() async {
        guard backend.currentUserID != nil else { phase = .signedOut; return }
        await loadPair()
    }

    // MARK: Sign-in

    func signIn(idToken: String, rawNonce: String, fullName: PersonNameComponents?) async {
        if myName.isEmpty, let given = fullName?.givenName { myName = given }
        await run {
            try await self.backend.signInWithApple(idToken: idToken, rawNonce: rawNonce, fullName: fullName)
            await self.loadPair()
        }
    }

    /// Hidden test sign-in (long-press the title on the welcome screen).
    func signInForTesting() async {
        await run {
            try await self.backend.signInForTesting()
            await self.loadPair()
        }
    }

    func signOut() {
        pairListener?.cancel()
        store?.stop()
        store = nil
        PushCenter.shared.onToken = nil
        SharedPairKey.removeAll()
        try? backend.signOut()
        phase = .signedOut
    }

    // MARK: Pairing

    func createCode() async {
        await run {
            let created = try await self.backend.createPair(publicKey: try self.myPublicKey())
            self.phase = .waitingForPartner(code: created.code, pairID: created.pairID)
            self.watch(created.pairID)
        }
    }

    func join(code: String) async {
        await run {
            try await self.backend.joinPair(code: code, publicKey: try self.myPublicKey())
            await self.loadPair()
        }
    }

    /// "Bağlantıyı bitir": ends the pair for both phones and returns here to the code screen.
    /// My note stays on this phone and goes to the next pair.
    func endPair() async {
        guard case .paired(let pair) = phase else { return }
        await run {
            try await self.backend.endPair(pair.id)
            self.leavePair()
        }
    }

    private func leavePair() {
        pairListener?.cancel()
        pairListener = nil
        store?.stop()
        store = nil
        PushCenter.shared.onToken = nil
        SharedPairKey.removeAll()
        phase = .unpaired
    }

    func cancelWaiting() {
        pairListener?.cancel()
        phase = .unpaired
    }

    // MARK: Internals

    /// This device's public key for the signed-in account (identity created on first use).
    private func myPublicKey() throws -> Data {
        guard let me = backend.currentUserID else { throw BackendError.notSignedIn }
        return try PairCrypto.identity(for: me).publicKey.rawRepresentation
    }

    private func session(for pair: PairInfo) -> PairCrypto.Session? {
        guard let me = backend.currentUserID, let partner = pair.memberIDs.first(where: { $0 != me }) else { return nil }
        return try? PairCrypto.session(pairID: pair.id, myID: me, partnerID: partner, publicKeys: pair.publicKeys)
    }

    private func loadPair() async {
        do {
            // Ended pairs stay on the server but are never opened again.
            let pairs = try await backend.currentPairs().filter { !$0.ended }
            // Only a pair whose key this phone holds can be opened here.
            if let pair = pairs.first(where: { session(for: $0) != nil }) {
                enterPaired(pair)
                watch(pair.id)
            } else {
                phase = .unpaired
                if !pairs.isEmpty {
                    errorMessage = "Bu telefonda eski bağlantının şifreleme anahtarı yok. Uçtan uca şifreli yeni bir bağlantı kurun."
                }
            }
        } catch {
            phase = .unpaired
            errorMessage = Self.describe(error)
        }
    }

    private func watch(_ pairID: String) {
        pairListener?.cancel()
        pairListener = backend.observePair(pairID) { [weak self] pair in
            Task { @MainActor in
                guard let self else { return }
                if pair.ended {
                    self.leavePair()
                    self.errorMessage = "Bu bağlantı bitirildi. Yeniden bağlanmak için yeni bir kod oluşturun."
                } else if pair.isComplete {
                    self.enterPaired(pair)
                }
            }
        }
    }

    private func enterPaired(_ pair: PairInfo) {
        if let store, store.pair.id == pair.id {
            store.update(pair: pair)
        } else if let me = backend.currentUserID, let session = session(for: pair) {
            store?.stop()
            let fresh = WatchlinkStore(backend: backend, pair: pair, myID: me, session: session)
            fresh.start()
            store = fresh
            // Once paired: ask for notifications and give the partner (sealed) our push address.
            PushCenter.shared.onToken = { [weak fresh] token in
                Task { await fresh?.savePushToken(token) }
            }
            if !Self.isDemo { Task { await PushCenter.shared.register() } }
        } else {
            return  // keys not in place yet (or not on this phone)
        }
        phase = .paired(pair)
        // Each person names themselves once; the name travels sealed with the pair.
        let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let store, store.myName.isEmpty, !name.isEmpty {
            myName = ""
            Task { await store.saveProfile(name: name) }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do { try await work() } catch { errorMessage = Self.describe(error) }
    }

    /// The simulator UI tour: no notification prompt (it would cover the screens).
    static var isDemo: Bool {
        #if DEBUG
        DemoMode.isOn
        #else
        false
        #endif
    }

    static func describe(_ error: Error) -> String {
        switch error as? BackendError {
        case .invalidCode: return "Bu kod doğru görünmüyor. 8 karakteri de kontrol et."
        case .codeExpired: return "Bu kodun süresi dolmuş. Yeni bir kod iste."
        case .pairFull: return "Bu bağlantı zaten tamamlanmış ya da süresi dolmuş."
        case .photoTooLarge: return "Bu fotoğraf çok büyük."
        case .notSignedIn: return "Önce giriş yapmalısın."
        case .noPair: return "Bağlantı bulunamadı."
        case nil: return "Bir şeyler ters gitti. Bağlantını kontrol edip tekrar dene."
        }
    }
}
