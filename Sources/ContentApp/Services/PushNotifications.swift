import SwiftUI
import UIKit
import UserNotifications

/// Push notifications (Abel, 3 Nov 2026): a ping when a video, picture, voice
/// or reply is done. The server sends them (push-run, agent-chat); this is the
/// phone's half: its address for pings, and what a tap opens.
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var session: AppSession? {
        didSet {
            // A ping tapped while the app was closed arrives before the session.
            guard let waiting, let session else { return }
            self.waiting = nil
            session.openFromPush(waiting)
        }
    }
    private var waiting: UUID?

    /// The conversation on screen. Its own pings are not shown over it.
    static var openThread: UUID?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await session?.registerPush(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let thread = notification.request.content.userInfo["thread"] as? String
        return await isOnScreen(thread) ? [] : [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let thread = response.notification.request.content.userInfo["thread"] as? String
        await open(thread)
    }

    private func isOnScreen(_ thread: String?) -> Bool {
        guard let thread, let open = Self.openThread else { return false }
        return UUID(uuidString: thread) == open
    }

    private func open(_ thread: String?) {
        guard let thread, let id = UUID(uuidString: thread) else { return }
        if let session { session.openFromPush(id) } else { waiting = id }
    }
}

extension AppSession {
    private static let pushTokenKey = "pushToken"

    /// Once signed in, on every launch: a phone that already said yes registers
    /// again, because Apple can change its address.
    func refreshPushRegistration() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Asked once, the first time something is sent in a chat: in context, when
    /// there is about to be something worth a ping, rather than at launch.
    func askForPushOnce() async {
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func registerPush(token: String) async {
        UserDefaults.standard.set(token, forKey: Self.pushTokenKey)
        struct Params: Encodable { let p_token: String; let p_environment: String }
        _ = try? await client
            .rpc("register_push_device", params: Params(p_token: token, p_environment: "production"))
            .execute()
    }

    /// Signing out: this phone stops getting that account's pings.
    func forgetPush() async {
        guard let token = UserDefaults.standard.string(forKey: Self.pushTokenKey) else { return }
        _ = try? await client.rpc("forget_push_device", params: ["p_token": token]).execute()
    }

    /// A tapped ping opens its conversation.
    func openFromPush(_ thread: UUID) {
        guard PushDelegate.openThread != thread else { return }
        path.append(AppRoute.chat(thread))
    }
}
