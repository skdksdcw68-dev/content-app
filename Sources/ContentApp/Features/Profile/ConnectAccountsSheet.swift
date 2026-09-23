import SwiftUI

/// Where it posts, as a sheet: each platform with Connect beside it, the
/// connected ones showing who they are. Opened from wherever an account
/// is missing, instead of sending somebody to Profile to hunt for it
/// (Abel, 23 Sep 2026: "connect account should open a connection sheet
/// instead of redirecting you to profile").
struct ConnectAccountsSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                    Text("Autocast posts only what you approve. Instagram needs a Business or Creator account.")
                }
            }
            .navigationTitle("Connect accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
