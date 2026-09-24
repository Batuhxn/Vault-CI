import SwiftUI

struct WatchlinkRootView: View {
    @State private var store = WatchlinkStore()
    @State private var showingSetup = false
    @State private var scanning = false
    @State private var showingReviewInfo = false

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
                WatchlinkPrimaryButton(title: "Create Link") { scanning = false; showingSetup = false; store.beginPairing() }
                Button("Scan Link") { scanning = true; showingSetup = false; store.beginPairing() }
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
                Text(scanning ? "Scan Link" : "Link Code").font(.system(size: 17, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 48, height: 1)
            }.padding(.horizontal, 24).frame(height: 52)
            Divider().overlay(WatchlinkStyle.hairline)
            Spacer()
            Image(systemName: scanning ? "viewfinder" : "qrcode")
                .font(.system(size: 110, weight: .ultraLight))
                .foregroundStyle(WatchlinkStyle.secondary.opacity(0.45))
                .frame(width: 232, height: 232)
                .background(WatchlinkStyle.surface, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel("Link code will appear when secure pairing is available")
            Text("Secure linking is not available yet.")
                .font(.system(size: 17, weight: .semibold)).padding(.top, 24)
            Text(scanning ? "The scanner will open here when secure pairing is ready." : "A link code will appear here when secure pairing is ready.")
                .font(.system(size: 15)).foregroundStyle(WatchlinkStyle.secondary)
                .multilineTextAlignment(.center).padding(.top, 5)
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(WatchlinkStyle.away).frame(width: 7, height: 7)
                Text("Waiting for secure pairing").font(.system(size: 13))
            }.foregroundStyle(WatchlinkStyle.secondary).padding(.bottom, 34)
        }
        .padding(.horizontal, 24)
    }

    private var identityReview: some View {
        statusPage("Security identity changed", "The linked device's identity changed. Sending is paused until it can be reviewed.", symbol: "exclamationmark.shield")
            .safeAreaInset(edge: .bottom) {
                WatchlinkPrimaryButton(title: "Review security") { showingReviewInfo = true }.padding(24)
            }
    }

    private var unavailable: some View {
        statusPage("Messaging unavailable", "Secure messaging is not available yet.", symbol: "lock.shield")
            .safeAreaInset(edge: .bottom) {
                WatchlinkPrimaryButton(title: "Back") { store.transition(to: .notPaired) }.padding(24)
            }
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
