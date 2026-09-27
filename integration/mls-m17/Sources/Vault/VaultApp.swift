import SwiftUI

@main
struct VaultApp: App {
    // Production composition: the qualified MLS engine behind the relay transport.
    @State private var app = WatchlinkComposition.make()

    var body: some Scene {
        WindowGroup { WatchlinkRootView(store: app.0, transport: app.1) }
    }
}
