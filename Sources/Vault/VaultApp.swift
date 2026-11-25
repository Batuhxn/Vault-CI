import SwiftUI

@main
struct VaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // MVP composition (2026-11-25): Firebase backend behind ChatBackend.
    // The MLS engine is parked on branch park/mls-e2ee and is not started here.
    @State private var model = AppModel(backend: BackendBootstrap.makeBackend())

    var body: some Scene {
        WindowGroup { AppRootView(model: model) }
    }
}
