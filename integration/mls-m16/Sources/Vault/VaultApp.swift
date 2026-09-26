import SwiftUI

@main
struct VaultApp: App {
    // Production composition: the qualified MLS engine; no relay until M1.7.
    @State private var store = WatchlinkStore(engine: MLSCryptoEngine())

    var body: some Scene {
        WindowGroup { WatchlinkRootView(store: store) }
    }
}
