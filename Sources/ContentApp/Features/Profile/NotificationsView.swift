import Supabase
import SwiftUI
import UserNotifications

/// Settings › Notifications, in Grok's layout (Abel, 3 Nov 2026): one switch for
/// everything, then one per kind of thing that can be ready. Saved on the
/// account as `notify_off`, which the server reads before every ping.
struct NotificationsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    @State private var off: Set<String> = []
    /// The phone itself said no, so no switch here can turn pings on.
    @State private var blocked = false

    private struct Kind: Identifiable {
        let id: String
        let title: String
    }

    private static let kinds = [
        Kind(id: "video", title: "Videos"), Kind(id: "picture", title: "Pictures"),
        Kind(id: "voice", title: "Voice"), Kind(id: "reply", title: "Chat replies"),
    ]

    var body: some View {
        List {
            Section {
                Toggle(isOn: binding("all")) {
                    Label("Notifications", systemImage: "bell")
                }
            } footer: {
                if blocked {
                    Button("Turned off for Postpilot in iPhone Settings. Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .font(.footnote)
                }
            }

            Section {
                ForEach(Self.kinds) { kind in
                    Toggle(kind.title, isOn: binding(kind.id))
                }
            } header: {
                Text("Tell me when it's ready")
            } footer: {
                Text("No ping for the chat you are looking at.")
            }
            .disabled(off.contains("all"))

            Section {
                Toggle("When a drop arrives", isOn: binding("drop"))
                    .disabled(off.contains("all"))
                NavigationLink("Scheduled drops") { ScheduledDropsView() }
            } header: {
                Text("Scheduled")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            off = session.notificationsOff()
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            blocked = status == .denied
        }
    }

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !off.contains(key) },
            set: { on in
                withAnimation(.snappy(duration: 0.25)) {
                    if on { off.remove(key) } else { off.insert(key) }
                }
                let saved = off
                Task {
                    if on, key == "all" { await session.askForPushOnce() }
                    await session.setNotificationsOff(saved)
                }
            }
        )
    }
}

extension AppSession {
    /// What this person turned off, from the account (see `_shared/push.ts`).
    func notificationsOff() -> Set<String> {
        guard case .array(let list) = client.auth.currentUser?.userMetadata["notify_off"] else { return [] }
        return Set(list.compactMap { item -> String? in
            if case .string(let key) = item { return key }
            return nil
        })
    }

    func setNotificationsOff(_ keys: Set<String>) async {
        do {
            _ = try await client.auth.update(user: UserAttributes(data: ["notify_off": .array(keys.sorted().map { .string($0) })]))
        } catch {
            lastError = readableMessage(error)
        }
    }
}
