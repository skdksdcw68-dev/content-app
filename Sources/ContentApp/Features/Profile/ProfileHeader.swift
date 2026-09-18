import SwiftUI

/// The top of Profile: who is posting, how the account is doing, and which of
/// your apps everything below is about.
///
/// Every number is read, never estimated: followers, likes and videos are what
/// TikTok last reported; "By Autocast" counts targets Autocast actually
/// published. A number that has not loaded shows a dash, not a zero.
struct ProfileHeader: View {
    @Environment(AppSession.self) private var session
    @Binding var addingBrand: Bool

    @State private var account: PostsLibrary.Account?
    @State private var published: Int?

    private var connection: PlatformConnection? {
        session.connections.first(where: \.isHealthy) ?? session.connections.first
    }

    var body: some View {
        VStack(spacing: 14) {
            avatar

            VStack(spacing: 3) {
                if let connection {
                    Text(connection.displayName.trimmingCharacters(in: .whitespaces).isEmpty
                         ? connection.label : connection.displayName)
                        .font(.title2.weight(.bold))
                    Text(connection.label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(session.brand?.name ?? "Your account")
                        .font(.title2.weight(.bold))
                    Text("No TikTok connected yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if connection != nil {
                stats
            } else {
                Button {
                    Task { await session.connectTikTok() }
                } label: {
                    Label(session.isConnecting ? "Opening TikTok…" : "Connect TikTok", systemImage: "plus")
                        .frame(maxWidth: 220)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .disabled(session.isConnecting)
            }

            brandChips
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
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
        .frame(width: 84, height: 84)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            Stat(value: account?.followers, label: "Followers")
            divider
            Stat(value: account?.likes, label: "Likes")
            divider
            Stat(value: account?.videoCount, label: "Videos")
            divider
            Stat(value: published, label: "By Autocast")
        }
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 0.5, height: 28)
    }

    /// Your apps as chips. Tapping one makes it the one every page is about.
    private var brandChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.brands) { brand in
                    let chosen = brand.id == session.brand?.id
                    Button {
                        Task { await session.switchBrand(to: brand.id) }
                    } label: {
                        Text(brand.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(chosen ? Theme.onAccent : Color.primary)
                            .background(
                                chosen ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }

                Button { addingBrand = true } label: {
                    Image(systemName: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(Color.primary)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add an app")
            }
            .padding(.horizontal, 2)
        }
        .scrollClipDisabled()
    }

    private func load() async {
        account = nil
        published = nil
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
        VStack(spacing: 2) {
            Group {
                if let value {
                    Text(value, format: .number.notation(.compactName))
                        .contentTransition(.numericText(value: Double(value)))
                } else {
                    Text("–")
                }
            }
            .font(.headline.monospacedDigit())
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
