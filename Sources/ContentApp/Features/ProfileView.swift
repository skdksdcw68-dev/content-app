import SwiftUI

/// Who this account is, and what it is allowed to post to.
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @State private var addingGenerator = false

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

            Section {
                if session.generators.isEmpty {
                    NoGeneratorRow()
                } else {
                    ForEach(session.generators) { generator in
                        GeneratorRow(generator: generator) {
                            Task { await session.forgetGenerator(generator.id) }
                        }
                    }
                }

                Button {
                    addingGenerator = true
                } label: {
                    Label("Add a generator", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Generators")
            } footer: {
                Text("Autocast makes the videos with a generator you pay for, using your own key. Nothing is generated without one.")
            }

            Section("Coming next") {
                SoonRow(symbol: "music.note", title: "Music", detail: "A track picked and mixed into each video.")
                SoonRow(symbol: "camera.aperture", title: "More platforms", detail: "Instagram Reels and YouTube Shorts.")
            }
        }
        .navigationTitle("You")
        .refreshable {
            await session.refreshConnections()
            await session.refreshGenerators()
        }
        .sheet(isPresented: $addingGenerator) { GeneratorSheet() }
    }
}

// MARK: - Generators

private struct GeneratorRow: View {
    let generator: Generator
    let forget: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15))
                .foregroundStyle(generator.isWorking ? Theme.accent : Color.orange)
                .frame(width: 34, height: 34)
                .background(
                    (generator.isWorking ? Theme.accent : Color.orange).opacity(0.12),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(generator.name)
                    .font(.subheadline.weight(.medium))
                Text(generator.statusLine)
                    .font(.caption)
                    .foregroundStyle(generator.isWorking ? Color.secondary : Color.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
        }
        .swipeActions(edge: .trailing) {
            Button("Remove", role: .destructive, action: forget)
        }
    }
}

private struct NoGeneratorRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No generator connected")
                .font(.subheadline.weight(.medium))
            Text("Add your Higgsfield key and Autocast can make the videos your plan describes.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
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
