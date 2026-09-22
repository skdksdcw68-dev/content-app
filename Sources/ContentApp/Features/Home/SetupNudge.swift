import SwiftUI

/// The two things worth nagging about, once somebody is already inside:
/// saving the account, and connecting somewhere to post.
///
/// Neither is asked during onboarding any more (Abel, 21 Sep 2026: asking for
/// connections before anyone has seen the app "makes the user leave"). This
/// comes back at most once a day, and closes without argument.
struct SetupNudge: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var signingUp = false

    /// Shown once, ever (Abel, 22 Sep 2026: "why does it always appear dude?
    /// we want it only 1 time actually").
    @AppStorage("setupNudge.shown") private static var alreadyShown = false

    private var needsAccount: Bool { session.isAnonymous }
    private var missing: [Platform] { Platform.allCases.filter { session.connection(for: $0) == nil } }

    var body: some View {
        NavigationStack {
            List {
                if needsAccount {
                    Section {
                        Button { signingUp = true } label: {
                            SettingsRow("Save your account", symbol: "person.crop.circle.badge.checkmark", accessory: .chevron)
                        }
                    } header: {
                        Text("Keep what you make")
                    } footer: {
                        Text("Right now everything lives on this iPhone only. Saving it takes one tap with Apple or Google.")
                    }
                }

                Section {
                    ForEach(Platform.allCases) { platform in
                        if let connection = session.connection(for: platform) {
                            SettingsRow(platform.networkName, symbol: platform.symbolName, value: connection.label)
                        } else {
                            Button {
                                Task { await session.connect(platform) }
                            } label: {
                                SettingsRow(platform.networkName, symbol: platform.symbolName,
                                            value: session.isConnecting ? "Opening…" : "Connect", accessory: .chevron)
                            }
                            .disabled(session.isConnecting)
                        }
                    }
                } header: {
                    Text("Where to post")
                } footer: {
                    Text("Autocast posts only what you approve. You can connect these any time in Profile → Accounts.")
                }
            }
            .navigationTitle("Finish setting up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
            .sheet(isPresented: $signingUp) {
                AuthSheet { signingUp = false }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Worth showing: something is still missing, and not today already.
    static func due(_ session: AppSession) -> Bool {
        guard session.onboarding == .done else { return false }
        // Signing up is part of first run now, so this is only ever about
        // having somewhere to post.
        guard session.connections.isEmpty else { return false }
        return !alreadyShown
    }

    static func markShown() { alreadyShown = true }
}
