import SwiftUI

/// The top of Profile: who is posting and how the account is doing.
///
/// Numbers sit straight on the page, no card behind them (Abel, 19 Sep 2026:
/// "remove the card from the numbers background… clean"). Every number is
/// read, never estimated: followers, likes and videos are what TikTok last
/// reported; "By Autocast" counts what Autocast actually published. A number
/// that has not loaded is a dash, not a zero.
struct ProfileHeader: View {
    @Environment(AppSession.self) private var session

    @State private var account: PostsLibrary.Account?
    @State private var published: Int?

    private var connection: PlatformConnection? {
        session.connections.first(where: \.isHealthy) ?? session.connections.first
    }

    private var title: String {
        if let connection, !connection.displayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return connection.displayName
        }
        return session.brand?.name ?? "Your profile"
    }

    var body: some View {
        VStack(spacing: 0) {
            avatar

            Text(title)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .padding(.top, 12)

            Text(connection?.label ?? "No TikTok connected")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            if connection != nil {
                HStack(alignment: .top, spacing: 0) {
                    Stat(value: account?.followers, label: "Followers")
                    Stat(value: account?.likes, label: "Likes")
                    Stat(value: account?.videoCount, label: "Videos")
                    Stat(value: published, label: "By Autocast")
                }
                .padding(.top, 20)
            } else {
                Button {
                    Task { await session.connectTikTok() }
                } label: {
                    Text(session.isConnecting ? "Opening TikTok…" : "Connect TikTok")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .disabled(session.isConnecting)
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .task(id: session.brand?.id) { await load() }
    }

    private var avatar: some View {
        AsyncImage(url: connection?.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private func load() async {
        let lib = try? await session.postsLibrary()
        let over = try? await session.autopilotOverview()
        withAnimation(.snappy) {
            account = lib?.account
            published = over?.counts.published
        }
    }
}

private struct Stat: View {
    let value: Int?
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let value {
                    Text(value, format: .number.notation(.compactName))
                        .contentTransition(.numericText(value: Double(value)))
                } else {
                    Text("–")
                }
            }
            .font(.title3.weight(.bold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
