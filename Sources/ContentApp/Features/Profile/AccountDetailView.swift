import SwiftUI

/// One connected TikTok account: who it is, what Autocast may do with it, and
/// the two things you can do about it -- reconnect, or disconnect for real.
struct AccountDetailView: View {
    let connection: PlatformConnection

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDisconnect = false
    @State private var disconnecting = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AsyncImage(url: connection.avatarURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.label).font(.headline)
                        Text(connection.platform.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)

                LabeledContent("Status") {
                    Label(connection.isHealthy ? "Connected" : "Needs attention",
                          systemImage: connection.isHealthy ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(connection.isHealthy ? Color.green : Color.orange)
                }
                LabeledContent("Connected", value: connection.connectedAt.formatted(date: .abbreviated, time: .omitted))
            } footer: {
                if let problem = connection.problem { Text(problem) }
            }

            Section {
                ForEach(connection.scopes, id: \.self) { scope in
                    Label(Self.plain(scope), systemImage: Self.symbol(scope))
                }
            } header: {
                Text("What Autocast can do")
            } footer: {
                Text("Autocast never sees your TikTok password, and can’t do anything you haven’t allowed here.")
            }

            Section {
                Label {
                    Text("While Autocast is in TikTok’s review, it can only post straight to private accounts. Drafts work on any account.")
                        .font(.subheadline)
                } icon: {
                    SettingsIcon("lock")
                }
            }

            Section {
                Button {
                    Task { await session.connectTikTok() }
                } label: {
                    SettingsRow(session.isConnecting ? "Opening TikTok…" : "Reconnect", symbol: "arrow.triangle.2.circlepath")
                }
                .disabled(session.isConnecting)
            }

            Section {
                Button(role: .destructive) {
                    confirmingDisconnect = true
                } label: {
                    HStack {
                        Spacer()
                        if disconnecting { ProgressView() } else { Text("Disconnect") }
                        Spacer()
                    }
                }
                .disabled(disconnecting)
            }
        }
        .navigationTitle(connection.label)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Disconnect \(connection.label)?", isPresented: $confirmingDisconnect) {
            Button("Cancel", role: .cancel) {}
            Button("Disconnect", role: .destructive) {
                Task {
                    disconnecting = true
                    let done = await session.disconnectAccount(connection)
                    disconnecting = false
                    if done { dismiss() }
                }
            }
        } message: {
            Text("Autocast loses access at TikTok and anything scheduled for this account is cancelled. Your videos on TikTok stay as they are.")
        }
    }

    /// TikTok's scope names, in words.
    static func plain(_ scope: String) -> String {
        switch scope {
        case "user.info.basic":   "See your name and picture"
        case "user.info.profile": "See your profile and handle"
        case "user.info.stats":   "See follower and like counts"
        case "video.list":        "See your public videos and views"
        case "video.publish":     "Post videos you approve"
        case "video.upload":      "Send videos to your drafts"
        default:                  scope
        }
    }

    static func symbol(_ scope: String) -> String {
        switch scope {
        case "user.info.basic", "user.info.profile": "person"
        case "user.info.stats":   "chart.bar"
        case "video.list":        "play.rectangle"
        case "video.publish":     "paperplane"
        case "video.upload":      "tray.and.arrow.down"
        default:                  "checkmark"
        }
    }
}
