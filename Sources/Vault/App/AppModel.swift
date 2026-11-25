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
        try? backend.signOut()
        phase = .signedOut
    }

    // MARK: Pairing

    func createCode() async {
        await run {
            let created = try await self.backend.createPair()
            self.phase = .waitingForPartner(code: created.code, pairID: created.pairID)
            self.watch(created.pairID)
        }
    }

    func join(code: String) async {
        await run {
            try await self.backend.joinPair(code: code)
            await self.loadPair()
        }
    }

    func cancelWaiting() {
        pairListener?.cancel()
        phase = .unpaired
    }

    // MARK: Internals

    private func loadPair() async {
        do {
            if let pair = try await backend.currentPair(), pair.isComplete {
                enterPaired(pair)
                watch(pair.id)
            } else {
                phase = .unpaired
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
                if pair.isComplete { self.enterPaired(pair) }
            }
        }
    }

    private func enterPaired(_ pair: PairInfo) {
        if let store, store.pair.id == pair.id {
            store.update(pair: pair)
        } else if let me = backend.currentUserID {
            store?.stop()
            let fresh = WatchlinkStore(backend: backend, pair: pair, myID: me)
            fresh.start()
            store = fresh
        }
        phase = .paired(pair)
        // Each person names themselves once; the name travels with the pair.
        let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let me = backend.currentUserID, pair.names[me] == nil, !name.isEmpty {
            myName = ""
            Task { try? await self.backend.saveMyName(name, pairID: pair.id) }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) async {
        busy = true
        errorMessage = nil
        defer { busy = false }
        do { try await work() } catch { errorMessage = Self.describe(error) }
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
