import FirebaseCore

/// App start-up hook so that only Backend/ imports Firebase.
@MainActor
enum BackendBootstrap {
    static func makeBackend() -> any ChatBackend {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        return FirebaseChatBackend()
    }
}
