import SwiftUI

struct WatchlinkRootView: View {
    let store: WatchlinkStore
    let transport: LiveTransport?
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingReset = false
    @State private var showingReviewInfo = false
    @State private var pairingError = false
    @State private var showingDiagnostics = false

    init(store: WatchlinkStore, transport: LiveTransport? = nil) {
        self.store = store
        self.transport = transport
    }

    var body: some View {
        Group {
            switch store.rootState {
            case .welcome: welcome
            case .pairing: pairing
            case .establishing: statusPage("Verifying secure link", "Keep both devices open.", symbol: "arrow.triangle.2.circlepath")
            case .chats: ChatsHomeView(store: store)
            case .identityReview: identityReview
            case .unavailable: unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .foregroundStyle(WatchlinkStyle.text)
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.reopenIfUnavailable() } }
        // Foreground-only delivery; nothing depends on the app staying alive.
        .task(id: scenePhase == .active) { if scenePhase == .active { await transport?.run() } }
        // Presentation is bound to store state that only user actions and scan
        // results change; periodic refreshes never dismiss it.
        .fullScreenCover(isPresented: Binding(get: { store.scanner == .scanning },
                                              set: { if !$0 { store.cancelScan() } })) {
            PairingScannerScreen(
                onCode: { code in
                    switch store.scanned(code) {
                    case .ignored: return false
                    case .accepted: return true
                    case .rejected:
                        // Shown after the scanner has finished dismissing.
                        Task { try? await Task.sleep(for: .milliseconds(600)); pairingError = true }
                        return true
                    }
                },
                onCancel: { store.cancelScan() },
                onFailure: { store.scannerFailed() })
        }
        .alert("Camera access needed", isPresented: Binding(get: { store.scanner == .permissionDenied },
                                                           set: { if !$0 { store.acknowledgeScannerNotice() } })) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Allow camera access in Settings to scan your partner's code.") }
        .alert("Camera unavailable", isPresented: Binding(get: { store.scanner == .failed },
                                                          set: { if !$0 { store.acknowledgeScannerNotice() } })) {
            Button("OK", role: .cancel) { }
        } message: { Text("The camera could not be started. Try again.") }
        #if WATCHLINK_QUALIFICATION
        .overlay(alignment: .topTrailing) {
            Button { showingDiagnostics = true } label: { Image(systemName: "stethoscope").padding(12) }
                .accessibilityLabel("Qualification diagnostics")
        }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(store: store, transport: transport) }
        #endif
        .alert("Code not accepted", isPresented: $pairingError) {
            Button("OK", role: .cancel) { }
        } message: { Text("That code is expired, already used, or not for this link. Start again with a new code.") }
        .confirmationDialog("Reset security?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Security", role: .destructive) { store.resetSecurity() }
        } message: { Text("This removes the link and this device's security identity. You will need to link again.") }
        .alert("Review unavailable", isPresented: $showingReviewInfo) {
            Button("OK", role: .cancel) { }
        } message: { Text("Security review will be available with secure linking.") }
    }

    private var welcome: some View {
        VStack {
            Spacer()
            VStack(spacing: 24) {
                WatchlinkMark()
                VStack(spacing: 8) {
                    Text("Watchlink").font(.system(size: 28, weight: .semibold))
                    Text("A quiet, private line between two devices.")
                        .font(.system(size: 17)).foregroundStyle(WatchlinkStyle.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 280)
                }
            }
            Spacer()
            VStack(spacing: 16) {
                WatchlinkPrimaryButton(title: "Create Secure Link") { if !store.createLink() { pairingError = true } }
                Button("Scan Partner Code") { store.beginPairing(); Task { await store.requestScan() } }
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchlinkStyle.tint)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(WatchlinkStyle.soft, in: RoundedRectangle(cornerRadius: 14))
                Text("by Batuhxn").font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
            }
            .padding(.horizontal, 24).padding(.bottom, 34)
        }
    }

    private var pairing: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { store.cancelPairing() }.foregroundStyle(WatchlinkStyle.tint)
                Spacer()
                Text("Link Code").font(.system(size: 17, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 48, height: 1)
            }.padding(.horizontal, 24).frame(height: 52)
            Divider().overlay(WatchlinkStyle.hairline)
            Spacer()
            switch store.pairingStep {
            case .showCode(let code, let scanPartnerNext):
                PairingCodeImage(code: code)
                    .padding(16).frame(width: 264, height: 264)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                Text("Waiting for partner").font(.system(size: 17, weight: .semibold)).padding(.top, 24)
                Text(scanPartnerNext ? "Show this code to your partner, then scan the code their device shows."
                                     : "Show this code to your partner to finish.")
                    .font(.system(size: 15)).foregroundStyle(WatchlinkStyle.secondary)
                    .multilineTextAlignment(.center).padding(.top, 5)
                if scanPartnerNext {
                    WatchlinkPrimaryButton(title: "Scan Partner Code") { Task { await store.requestScan() } }.padding(.top, 24)
                }
            case .waiting:
                statusPage("Verifying secure link", "Keep both devices open until the link is ready.", symbol: "arrow.triangle.2.circlepath")
            case .expired:
                statusPage("Code expired", "Cancel and create a new link.", symbol: "clock.badge.exclamationmark")
            case .none:
                statusPage("Scan partner code", "Scan the code shown on your partner's device.", symbol: "viewfinder")
                WatchlinkPrimaryButton(title: "Scan Partner Code") { Task { await store.requestScan() } }
            }
            Spacer()
            // Relay reachability is never shown as a secure state; only its absence is reported.
            if !store.connectionAvailable {
                HStack(spacing: 8) {
                    Circle().fill(WatchlinkStyle.secondary).frame(width: 7, height: 7)
                    Text("Connection unavailable").font(.system(size: 13))
                }.foregroundStyle(WatchlinkStyle.secondary).padding(.bottom, 34)
            }
        }
        .padding(.horizontal, 24)
    }

    private var identityReview: some View {
        statusPage("Security identity changed", "The linked device's identity changed. Sending is paused until it can be reviewed.", symbol: "exclamationmark.shield")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    WatchlinkPrimaryButton(title: "Review security") { showingReviewInfo = true }
                    resetButton
                }.padding(24)
            }
    }

    @ViewBuilder private var unavailable: some View {
        if store.securityState == .error {
            statusPage("Security reset required", "Secure messaging can't be restored on this device.", symbol: "lock.shield")
                .safeAreaInset(edge: .bottom) { resetButton.padding(24) }
        } else {
            statusPage("Messaging unavailable", "Secure messaging is not available right now.", symbol: "lock.shield")
                .safeAreaInset(edge: .bottom) {
                    WatchlinkPrimaryButton(title: "Back") { store.transition(to: .notPaired) }.padding(24)
                }
        }
    }

    private var resetButton: some View {
        Button("Reset Security") { confirmingReset = true }
            .font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchlinkStyle.tint)
            .frame(maxWidth: .infinity).frame(height: 50)
            .background(WatchlinkStyle.soft, in: RoundedRectangle(cornerRadius: 14))
    }

    private func statusPage(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(WatchlinkStyle.tint)
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(detail).font(.system(size: 15)).foregroundStyle(WatchlinkStyle.secondary)
                .multilineTextAlignment(.center)
        }.padding(32)
    }
}
