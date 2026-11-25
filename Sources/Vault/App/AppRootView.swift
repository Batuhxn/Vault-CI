import AuthenticationServices
import SwiftUI

private typealias Room = WatchlinkStyle.Room

/// Sign in -> pair -> RelationshipShell. The pre-pair screens use the same
/// room (cream ground, serif headline, one sage action) as Stage 2.
struct AppRootView: View {
    @State var model: AppModel

    var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ScreenScaffold { ProgressView().tint(Room.sage).frame(maxHeight: .infinity) }
            case .signedOut:
                WelcomeScreen(model: model)
            case .unpaired:
                PairScreen(model: model)
            case .waitingForPartner(let code, _):
                WaitingScreen(model: model, code: code)
            case .paired:
                if let store = model.store {
                    RelationshipShell(store: store)
                } else {
                    ScreenScaffold { ProgressView().tint(Room.sage).frame(maxHeight: .infinity) }
                }
            }
        }
        .preferredColorScheme(.light)  // Stage 2 is light-only until a dark theme ships
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

    var body: some View {
        ScreenScaffold {
            VStack(alignment: .leading, spacing: 0) {
                HeadlineBlock(meta: "Watchlink", headline: "İki kişilik\nsessiz bir hat.")
                Text("Senin telefonunla onunki arasında, sadece size ait bir alan.")
                    .font(.body)
                    .foregroundStyle(Room.ink2)
                    .padding(.horizontal, screenMargin)
                    .padding(.top, 14)
                Spacer()
                PairMonogram(partner: "", me: "")
                    .frame(maxWidth: .infinity)
                Spacer()
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
                .signInWithAppleButtonStyle(.black)
                .frame(height: 50)
                .clipShape(Capsule())
                .disabled(model.busy)
                .padding(.horizontal, screenMargin)
                Text("by Batuhxn")
                    .wlWhisper()
                    .foregroundStyle(Room.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
            }
        }
    }
}

// MARK: - Pair

private struct PairScreen: View {
    @Bindable var model: AppModel
    @State private var code = ""
    @FocusState private var focus: Field?
    private enum Field { case name, code }

    private var nameReady: Bool { !model.myName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScreenScaffold {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HeadlineBlock(meta: "Bağlantı", headline: "Birbirinizi\nbulun.")
                    Text("Biriniz kod oluştursun, diğeriniz o kodu girsin.")
                        .font(.body)
                        .foregroundStyle(Room.ink2)
                        .padding(.horizontal, screenMargin)
                        .padding(.top, 14)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Adın").font(.footnote.weight(.semibold)).foregroundStyle(Room.sage)
                        TextField("Partnerin seni bu adla görecek", text: $model.myName)
                            .textContentType(.givenName)
                            .focused($focus, equals: .name)
                            .submitLabel(.done)
                            .padding(.horizontal, 16).frame(height: 50)
                            .wlCard(radius: 18)
                    }
                    .padding(.horizontal, screenMargin)
                    .padding(.top, 40)

                    VStack(spacing: 12) {
                        Button { focus = nil; Task { await model.createCode() } } label: {
                            Text("Kod oluştur")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Room.cream)
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .background(Room.sage, in: Capsule())
                        }
                        .buttonStyle(Pressable())

                        Text("ya da").wlWhisper().foregroundStyle(Room.ink3)

                        HStack(spacing: 10) {
                            TextField("Onun kodu", text: $code)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .focused($focus, equals: .code)
                                .padding(.horizontal, 16).frame(height: 50)
                                .wlCard(radius: 18)
                                .onChange(of: code) { _, value in code = String(value.uppercased().prefix(8)) }
                            Button("Katıl") { focus = nil; Task { await model.join(code: code) } }
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Room.sageDeep)
                                .frame(width: 80, height: 50)
                                .background(Room.control, in: Capsule())
                                .buttonStyle(Pressable(scale: RelationshipMotion.pressControl))
                                .disabled(code.count != 8)
                        }
                    }
                    .disabled(!nameReady || model.busy)
                    .padding(.horizontal, screenMargin)
                    .padding(.top, 28)

                    Button("Çıkış yap") { model.signOut() }
                        .font(.footnote)
                        .foregroundStyle(Room.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 36)
                        .padding(.bottom, 24)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay { if model.busy { ProgressView().tint(Room.sage) } }
        }
    }
}

private struct WaitingScreen: View {
    let model: AppModel
    let code: String

    var body: some View {
        ScreenScaffold {
            VStack(alignment: .leading, spacing: 0) {
                HeadlineBlock(meta: "Kodun", headline: "Onu\nbekliyoruz.")
                Text(code.chunked(by: 4))
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Room.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .wlCard()
                    .padding(.horizontal, screenMargin)
                    .padding(.top, 36)
                Text("Bu kodu onun telefonuna gir. 15 dakika geçerli.")
                    .font(.subheadline)
                    .foregroundStyle(Room.ink2)
                    .padding(.horizontal, screenMargin)
                    .padding(.top, 16)
                HStack(spacing: 8) {
                    ProgressView().tint(Room.ink3).scaleEffect(0.8)
                    Text("Partnerin bekleniyor").wlWhisper().foregroundStyle(Room.ink3)
                }
                .padding(.horizontal, screenMargin)
                .padding(.top, 12)
                Spacer()
                Button { model.cancelWaiting() } label: {
                    Text("Vazgeç")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Room.sageDeep)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Room.control, in: Capsule())
                }
                .buttonStyle(Pressable())
                .padding(.horizontal, screenMargin)
                .padding(.bottom, 24)
            }
        }
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
