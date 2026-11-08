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
    /// The place tapped, waiting for a yes before anything opens.
    @State private var asking: Platform?

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
                            SettingsRow(platform.networkName, logo: platform.logo, value: connection.label)
                        } else {
                            Button {
                                asking = platform
                            } label: {
                                SettingsRow(platform.networkName, logo: platform.logo,
                                            value: session.isConnecting ? "Opening…" : "Connect", accessory: .chevron)
                            }
                            .disabled(session.isConnecting)
                        }
                    }
                } header: {
                    Text("Where to post")
                } footer: {
                    Text("Postpilot posts only what you approve. You can connect these any time in Profile → Accounts.")
                }
            }
            .navigationTitle("Finish setting up")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button { dismiss() } label: {
                    Text("Not now")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .confirmationDialog(
                asking.map { "Connect \($0.networkName)?" } ?? "",
                isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                titleVisibility: .visible
            ) {
                Button("Connect") {
                    if let place = asking { Task { await session.connect(place) } }
                    asking = nil
                }
                Button("Not now", role: .cancel) { asking = nil }
            } message: {
                Text("You will go to \(asking?.networkName ?? "it") to sign in, then come back here.")
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
