import AuthenticationServices
import SwiftUI

struct AppRootView: View {
    @State var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().tint(WatchlinkStyle.tint)
            case .signedOut:
                WelcomeScreen(model: model)
            case .unpaired:
                PairScreen(model: model)
            case .waitingForPartner(let code, _):
                WaitingScreen(model: model, code: code)
            case .paired(let pair):
                MainTabView(model: model, pair: pair)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .foregroundStyle(WatchlinkStyle.text)
        .tint(WatchlinkStyle.tint)
        .task { await model.start() }
        .alert("Watchlink", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Tamam", role: .cancel) { }
        } message: { Text(model.errorMessage ?? "") }
    }
}

// MARK: - Welcome

private struct WelcomeScreen: View {
    let model: AppModel
    @State private var nonce = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 24) {
                WatchlinkMark()
                VStack(spacing: 8) {
                    Text("Watchlink").font(.system(size: 28, weight: .semibold))
                    Text("İki kişi arasında sessiz, özel bir hat.")
                        .font(.system(size: 17)).foregroundStyle(WatchlinkStyle.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 280)
                }
            }
            Spacer()
            VStack(spacing: 16) {
                SignInWithAppleButton(.signIn) { request in
                    nonce = AppleSignIn.randomNonce()
                    request.requestedScopes = [.fullName]
                    request.nonce = AppleSignIn.sha256(nonce)
                } onCompletion: { result in
                    guard case .success(let authorization) = result,
                          let token = AppleSignIn.token(from: authorization) else {
                        if case .failure(let error) = result,
                           (error as? ASAuthorizationError)?.code != .canceled {
                            model.errorMessage = "Apple ile giriş tamamlanamadı."
                        }
                        return
                    }
                    Task { await model.signIn(idToken: token.idToken, rawNonce: nonce, fullName: token.fullName) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(model.busy)

                Text("by Batuhxn").font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
            }
            .padding(.horizontal, 24).padding(.bottom, 34)
        }
    }
}

// MARK: - Pair

private struct PairScreen: View {
    let model: AppModel
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            WatchlinkMark(size: 72)
            Text("Bağlantı kur").font(.system(size: 28, weight: .semibold))
            Text("Biriniz kod oluştursun, diğeriniz o kodu girsin.")
                .font(.system(size: 17)).foregroundStyle(WatchlinkStyle.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()

            WatchlinkPrimaryButton(title: "Kod oluştur") { Task { await model.createCode() } }
                .disabled(model.busy)

            HStack(spacing: 10) {
                TextField("Kodu gir", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .focused($focused)
                    .padding(.horizontal, 14).frame(height: 50)
                    .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: code) { _, value in code = String(value.uppercased().prefix(8)) }
                Button("Katıl") { focused = false; Task { await model.join(code: code) } }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 84, height: 50)
                    .background(WatchlinkStyle.soft, in: RoundedRectangle(cornerRadius: 14))
                    .disabled(code.count != 8 || model.busy)
            }

            Button("Çıkış yap") { model.signOut() }
                .font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
                .padding(.top, 4)
        }
        .padding(24)
        .overlay { if model.busy { ProgressView() } }
    }
}

private struct WaitingScreen: View {
    let model: AppModel
    let code: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Bağlantı kodun").font(.system(size: 17)).foregroundStyle(WatchlinkStyle.secondary)
            Text(code.chunked(by: 4))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 24).padding(.vertical, 18)
                .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 20))
            Text("Bu kodu diğer telefonda gir. 15 dakika geçerli.")
                .font(.system(size: 15)).foregroundStyle(WatchlinkStyle.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Bekleniyor…").font(.system(size: 13))
            }.foregroundStyle(WatchlinkStyle.secondary).padding(.top, 8)
            Spacer()
            Button("Vazgeç") { model.cancelWaiting() }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 50)
                .background(WatchlinkStyle.soft, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(24)
    }
}

private extension String {
    func chunked(by size: Int) -> String {
        stride(from: 0, to: count, by: size).map { offset -> String in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: size, limitedBy: endIndex) ?? endIndex
            return String(self[start..<end])
        }.joined(separator: " ")
    }
}
