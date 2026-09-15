import SwiftUI

/// Who this account is, and what it is allowed to post to.
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @State private var approving: PendingPost?

    /// Pasted keys that are not already shown as a connection.
    private var unbridgedGenerators: [Generator] {
        session.generators.filter { generator in
            !session.connectedProviders.contains { $0.id == generator.id }
        }
    }

    var body: some View {
        List {
            // Where Home's warnings went. First on this page, because the
            // badge on the tab is what brought somebody here.
            if !session.health.isEmpty || !session.failedRecently.isEmpty {
                Section {
                    ForEach(session.health) { finding in
                        AttentionRow(finding: finding)
                    }
                    ForEach(session.failedRecently.prefix(5)) { post in
                        Button { approving = post } label: {
                            FailedPostRow(post: post)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Needs attention")
                }
            }

            Section {
                NavigationLink {
                    BrandView()
                } label: {
                    BrandRow(brand: session.brand)
                }
            } footer: {
                // The planner writes only from what is in there, so an empty
                // brand is the single biggest cause of a generic month.
                if session.brand?.isComplete != true {
                    Text("It writes from what you put here. Two sentences makes a noticeable difference to the plan.")
                }
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
                // Providers connected by signing in. What each one can do is
                // shown rather than a tick -- "5 models · video, image" is the
                // question somebody actually has.
                ForEach(session.connectedProviders) { provider in
                    ProviderRow(provider: provider)
                }

                // Keys pasted before sign-in existed, and only those not
                // already listed above: 0028 bridged each key into a
                // connection with the same id, so without this filter one key
                // showed as two rows.
                ForEach(unbridgedGenerators) { generator in
                    GeneratorRow(generator: generator) {
                        Task { await session.forgetGenerator(generator.id) }
                    }
                }

                if session.connectedProviders.isEmpty && unbridgedGenerators.isEmpty {
                    NoGeneratorRow()
                }

                // Sign in, not paste a key. The connect list comes from the
                // server, so a provider added later appears here without this
                // file changing -- and a pasted key no longer hides it.
                ForEach(session.connectable) { provider in
                    Button {
                        Task { await session.connectProvider(provider.slug) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.action)
                                Text(provider.how)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.plus")
                        }
                    }
                    .disabled(session.isWorking)
                }
            } header: {
                Text("Generators")
            } footer: {
                Text("Sign in to the generator you already pay for. Autocast never sees or stores your password, and you are billed by them, not by us.")
            }

            Section {
                Toggle("Make the videos for me", isOn: Binding(
                    get: { session.settings?.isOn ?? false },
                    set: { on in Task { await session.setAutopilot(on) } }
                ))
                .disabled(session.settings == nil || !session.hasWorkingGenerator)

                if let state = session.autopilotState {
                    LabeledContent("Right now") {
                        Text(state.title)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let settings = session.settings, settings.isOn {
                    LabeledContent("Made") {
                        Text("\(settings.renderLeadHours)h before each post")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Hours", value: settings.quietWindow)
                }
            } header: {
                Text("Autopilot")
            } footer: {
                // Off by default and said out loud, because everything this
                // turns on spends money without asking again.
                if !session.hasWorkingGenerator {
                    Text("Connect a generator above and Autocast can start each video a day before its slot, without being asked.")
                } else if session.settings?.isOn == true {
                    Text("Each video is made about a day before its slot and comes back to you for approval. You are billed by your generator for what it makes. Nothing is posted until you approve it.")
                } else {
                    Text("Turn this on and Autocast starts each video about a day before its slot. It still comes back to you before anything is posted.")
                }
            }

            Section("Coming next") {
                SoonRow(symbol: "music.note", title: "Music", detail: "A track picked and mixed into each video.")
                SoonRow(symbol: "camera.aperture", title: "More platforms", detail: "Instagram Reels and YouTube Shorts.")
            }
        }
        .navigationTitle("You")
        .task {
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
        }
        .refreshable {
            await session.refreshConnections()
            await session.refreshGenerators()
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
            await session.refreshSettings()
            await session.refreshHealth()
            await session.refreshPosts()
        }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
    }
}

// MARK: - Needs attention

/// One finding from `autopilot_health`, with its one action when the fix lives
/// on another screen. Generator and connection fixes are further down this
/// same page, so those rows say what to do rather than link to where you are.
private struct AttentionRow: View {
    let finding: HealthFinding

    var body: some View {
        let row = Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(.subheadline.weight(.medium))
                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: finding.isBlocked ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(finding.isBlocked ? Color.orange : Color.secondary)
        }
        .padding(.vertical, 2)

        if finding.route.flatMap(HealthRoute.init(rawValue:)) == .plan {
            NavigationLink { PlanView() } label: { row }
        } else {
            row
        }
    }
}

private struct FailedPostRow: View {
    let post: PendingPost

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(post.caption.isEmpty ? post.post.hook : post.caption)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(post.failureReason ?? "It did not go out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(Color.orange)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// One connected provider, with its actions in plain sight.
///
/// Disconnect used to be a swipe and nothing else, and Abel could not find it
/// -- a destructive action that has to be discovered is one that effectively
/// does not exist. The swipe stays for people who expect it; the menu is the
/// way in for everyone else.
private struct ProviderRow: View {
    let provider: ProviderConnection

    @Environment(AppSession.self) private var session
    @State private var confirmingDisconnect = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(provider.isHealthy && provider.modelCount > 0 ? Color.green : Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.providerName)
                Text("\(provider.door) · \(provider.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Menu {
                if provider.isHealthy {
                    Button {
                        Task { await session.refreshCapabilities(provider.id) }
                    } label: {
                        Label("Check what it offers", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    Task { await session.connectProvider(provider.providerSlug) }
                } label: {
                    Label(provider.isPastedKey ? "Sign in instead" : "Sign in again", systemImage: "person.crop.circle")
                }
                Divider()
                Button(role: .destructive) {
                    confirmingDisconnect = true
                } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Options for \(provider.providerName)")
        }
        .swipeActions {
            Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
        }
        .confirmationDialog(
            "Disconnect \(provider.providerName)?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                Task { await session.disconnect(provider.id) }
            }
        } message: {
            Text(provider.isPastedKey
                 ? "Your pasted key is deleted from Autocast. Nothing changes in your Higgsfield account."
                 : "Autocast stops using this account and forgets its sign-in. You can sign in again any time.")
        }
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
            Text("Sign in to Higgsfield below and Autocast can make the videos your plan describes.")
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
