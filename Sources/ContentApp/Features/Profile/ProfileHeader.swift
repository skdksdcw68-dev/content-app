import SwiftUI

/// The top of Profile: your picture, your name, your handle. No follower or
/// like counts -- Autocast is not only TikTok, and those numbers live in
/// Analytics (Abel, 19 Sep 2026).
struct ProfileHeader: View {
    @Environment(AppSession.self) private var session

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

            if connection == nil {
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

}
