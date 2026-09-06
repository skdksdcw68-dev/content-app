import SwiftUI

/// Who this account is, and what it is allowed to post to.
struct ProfileView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        List {
            Section {
                BrandRow(brand: session.brand)
            }

            Section {
                if session.connections.isEmpty {
                    NoAccountsRow()
                } else {
                    ForEach(session.connections) { connection in
                        ConnectionRow(connection: connection)
                    }
                }

                Button {
                    Task { await session.connectTikTok() }
                } label: {
                    HStack(spacing: 10) {
                        if session.isConnecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text(session.isConnecting ? "Opening TikTok…" : "Connect TikTok")
                    }
                }
                .disabled(session.isConnecting)
            } header: {
                Text("Connected accounts")
            } footer: {
                // Said here rather than discovered later: the sandbox forces
                // every post private until TikTok approves the app, and someone
                // who does not know that concludes the product is broken.
                Text("Autocast will not plan for a platform with no account linked. While the app is in review, anything it posts stays private to you.")
            }

            Section("Coming next") {
                SoonRow(symbol: "bubble.left", title: "Chat", detail: "Ask for a month of content in your own words.")
                SoonRow(symbol: "checkmark.shield", title: "Approvals", detail: "See each post and its privacy setting before it goes out.")
                SoonRow(symbol: "chart.line.uptrend.xyaxis", title: "Insights", detail: "Views and followers, fed back into what it plans next.")
            }
        }
        .navigationTitle("You")
        .refreshable { await session.refreshConnections() }
    }
}

private struct BrandRow: View {
    let brand: Brand?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.softAccent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(brand?.name ?? "Your brand")
                    .font(.headline)
                Text(brand?.isComplete == true
                     ? (brand?.niche ?? "")
                     : "Tell it what you post about and it writes far better")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The creator, shown the way TikTok requires before anything is published:
/// their own avatar and handle, not a display name that is frequently blank.
private struct ConnectionRow: View {
    let connection: PlatformConnection

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: connection.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: connection.platform.symbolName)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(connection.label)
                    .font(.subheadline.weight(.medium))

                if let problem = connection.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .lineLimit(2)
                } else {
                    Text("\(connection.platform.displayName) · \(connection.scopes.count) permissions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: connection.isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(connection.isHealthy ? Color.green : Color.orange)
        }
        .padding(.vertical, 2)
    }
}

private struct NoAccountsRow: View {
    var body: some View {
        Text("Nothing connected yet.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

private struct SoonRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
