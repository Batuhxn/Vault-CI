import SwiftUI

struct WatchlinkRootView: View {
    let store: WatchlinkStore
    let transport: LiveTransport?
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSetup = false
    @State private var confirmingReset = false
    @State private var scanning = false
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
            case .establishing: statusPage("Setting up your link", "Waiting for a secure session.", symbol: "arrow.triangle.2.circlepath")
            case .chats: ChatsHomeView(store: store)
            case .identityReview: identityReview
            case .unavailable: unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WatchlinkStyle.background.ignoresSafeArea())
        .foregroundStyle(WatchlinkStyle.text)
        .sheet(isPresented: $showingSetup) { setup }
        .onChange(of: scenePhase) { _, phase in if phase == .active { store.reopenIfUnavailable() } }
        // Foreground-only delivery; nothing depends on the app staying alive.
        .task(id: scenePhase == .active) { if scenePhase == .active { await transport?.run() } }
        .sheet(isPresented: $scanning) {
            PairingScanner { code in
                scanning = false
                if !store.acceptScanned(code) { pairingError = true }
            }
            .ignoresSafeArea()
        }
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
                WatchlinkPrimaryButton(title: "Get Started") { showingSetup = true }
                Text("by Batuhxn").font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
            }
            .padding(.horizontal, 24).padding(.bottom, 34)
        }
    }

    private var setup: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                WatchlinkMark(size: 72)
                Text("Link a device").font(.system(size: 28, weight: .semibold))
                Text("Create a private connection with another Watchlink device.")
                    .font(.system(size: 17)).foregroundStyle(WatchlinkStyle.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Spacer()
                WatchlinkPrimaryButton(title: "Create Link") {
                    showingSetup = false
                    if !store.createLink() { pairingError = true }
                }
                Button("Scan Link") { showingSetup = false; store.beginPairing() }
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(WatchlinkStyle.tint)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(WatchlinkStyle.soft, in: RoundedRectangle(cornerRadius: 14))
                Text("Open Watchlink on the other device to begin.")
                    .font(.system(size: 13)).foregroundStyle(WatchlinkStyle.secondary)
            }
            .padding(24)
            .background(WatchlinkStyle.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { showingSetup = false } } }
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
                Text(scanPartnerNext ? "Show this code to your partner" : "Show this code to your partner to finish")
                    .font(.system(size: 17, weight: .semibold)).padding(.top, 24)
                Text(scanPartnerNext ? "Then scan the code their device shows you." : "Waiting for partner…")
                    .font(.system(size: 15)).foregroundStyle(WatchlinkStyle.secondary)
                    .multilineTextAlignment(.center).padding(.top, 5)
                if scanPartnerNext {
                    WatchlinkPrimaryButton(title: "Scan Partner's Code") { scanning = true }.padding(.top, 24)
                }
            case .waiting:
                statusPage("Waiting for partner…", "Keep both devices open until the link is ready.", symbol: "arrow.triangle.2.circlepath")
            case .expired:
                statusPage("Code expired", "Cancel and create a new link.", symbol: "clock.badge.exclamationmark")
            case .none:
                statusPage("Scan a link code", "Scan the code shown on your partner's device.", symbol: "viewfinder")
                WatchlinkPrimaryButton(title: "Scan Link") { scanning = true }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(store.connectionAvailable ? WatchlinkStyle.away : WatchlinkStyle.secondary).frame(width: 7, height: 7)
                Text(store.connectionAvailable ? "Connecting…" : "Connection unavailable").font(.system(size: 13))
            }.foregroundStyle(WatchlinkStyle.secondary).padding(.bottom, 34)
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
