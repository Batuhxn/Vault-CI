import UIKit
import UserNotifications

/// Where the phones ask for a push to be delivered: a small Cloudflare Worker
/// (workers/push). It checks, with the sender's own Firebase sign-in, that the
/// message really exists in a pair they belong to, then hands Apple a generic
/// notification plus the still-sealed message. Neither the Worker nor Apple
/// can read it; the partner's notification extension opens it on the phone.
enum PushConfig {
    /// `nil` would skip pushes (sending still works).
    static let endpoint: URL? = URL(string: "https://watchlink-push.watchlink-relay.workers.dev")
}

/// Notification permission and this device's APNs token.
@MainActor
final class PushCenter {
    static let shared = PushCenter()

    /// The current token as lowercase hex, once Apple has issued one.
    private(set) var token: String?
    /// Called with every new token (the store seals it into this member's profile).
    var onToken: ((String) -> Void)? {
        didSet { if let token { onToken?(token) } }
    }

    /// Asks once (iOS remembers the answer) and registers with APNs.
    func register() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard hex != token else { return }
        token = hex
        onToken?(hex)
    }
}

/// UIKit hooks SwiftUI doesn't offer: the APNs token and foreground presentation.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Timetable.registerCategory()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushCenter.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// While Watchlink is open the message is already on screen (and a heartbeat
    /// plays as haptics), so no banner on top of it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // Exam and class reminders are local and worth seeing even with the app open.
        let id = notification.request.identifier
        // Important school mail alerts come from the mail relay and are worth seeing too.
        let mailAlert = notification.request.content.userInfo["wlMail"] != nil
        return mailAlert || id.hasPrefix("wl.agenda.") || id.hasPrefix("wl.class.") ? [.banner, .sound, .list] : []
    }

    /// A class reminder's button (Gidiyorum / Gitmiyorum / Ders iptal / Muafım) marks that class.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        guard content.categoryIdentifier == "wl.class" else { return }
        let action = response.actionIdentifier
        let info = content.userInfo
        guard let key = info["key"] as? String else { return }
        await MainActor.run { Timetable.shared.handle(actionID: action, key: key) }
    }
}
