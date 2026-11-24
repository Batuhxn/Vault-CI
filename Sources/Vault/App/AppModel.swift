import Foundation
import Observation

/// Top-level flow: sign in -> pair -> main tabs.
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
    var errorMessage: String?
    var busy = false

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
        await run {
            try await self.backend.signInWithApple(idToken: idToken, rawNonce: rawNonce, fullName: fullName)
            await self.loadPair()
        }
    }

    func signOut() {
        pairListener?.cancel()
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

    // MARK: Heartbeat

    func saveMyBPM(_ bpm: Int) async {
        guard case .paired(let pair) = phase else { return }
        await run { try await self.backend.saveMyBPM(bpm, pairID: pair.id) }
    }

    // MARK: Internals

    private func loadPair() async {
        do {
            if let pair = try await backend.currentPair(), pair.isComplete {
                phase = .paired(pair)
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
                if pair.isComplete { self.phase = .paired(pair) }
            }
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
        case .invalidCode: return "Kod geçersiz. 8 karakteri kontrol et."
        case .codeExpired: return "Kodun süresi dolmuş. Yeni bir kod iste."
        case .pairFull: return "Bu bağlantı dolu ya da süresi geçmiş."
        case .photoTooLarge: return "Fotoğraf çok büyük."
        case .notSignedIn: return "Önce giriş yapmalısın."
        case .noPair: return "Bağlantı bulunamadı."
        case nil: return "Bir şeyler ters gitti. Bağlantını kontrol edip tekrar dene."
        }
    }
}
