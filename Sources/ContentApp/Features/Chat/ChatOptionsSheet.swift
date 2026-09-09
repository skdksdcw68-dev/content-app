import SwiftUI

/// What the plus offers.
///
/// A real sheet rather than a menu, because most of these open something of
/// their own and a menu that opens a sheet reads as a stutter.
///
/// The Connections section is driven by what is actually connected rather than
/// by a hardcoded list of vendor buttons. That is the whole point of the
/// connector work reaching the surface: a provider added later appears here
/// without this file changing, and one that is connected shows what it can
/// actually do instead of a checkmark.
struct ChatOptionsSheet: View {
    enum Action {
        case planMonth
        case ask(String)
        case connect(String)
        case reconnect(ProviderConnection)
        case refresh(ProviderConnection)
    }

    @Environment(AppSession.self) private var session
    let onPick: (Action) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Create") {
                    Row(
                        symbol: "video",
                        title: "Make a video",
                        detail: makeDetail
                    ) { onPick(.ask("Make me a video")) }

                    Row(
                        symbol: "calendar",
                        title: "Plan 30 days",
                        detail: "Writes and schedules a month at once"
                    ) { onPick(.planMonth) }
                }

                Section("Research") {
                    Row(
                        symbol: "magnifyingglass",
                        title: "Look into something",
                        detail: "Keeps working after you close the app"
                    ) { onPick(.ask("Research ")) }

                    Row(
                        symbol: "chart.line.uptrend.xyaxis",
                        title: "What's working",
                        detail: "Reads your own numbers back"
                    ) { onPick(.ask("What's working in my recent posts?")) }
                }

                Section {
                    ForEach(session.connectedProviders) { provider in
                        ConnectedRow(provider: provider) {
                            // A healthy connection is asked again what it
                            // offers; a broken one is signed into again.
                            // Re-asking is the cheaper fix and covers the
                            // commonest case — a connection that discovered
                            // nothing is not broken, it just has not been
                            // asked since the provider granted something.
                            onPick(provider.isHealthy ? .refresh(provider) : .reconnect(provider))
                        }
                    }

                    ForEach(session.connectable) { provider in
                        Row(
                            symbol: "plus.circle",
                            title: "Connect \(provider.name)",
                            detail: provider.how
                        ) { onPick(.connect(provider.slug)) }
                    }

                    if session.connectedProviders.isEmpty && session.connectable.isEmpty {
                        Text("Nothing to connect yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connections")
                } footer: {
                    Text("Signing in keeps the key on our side — Autocast never stores it on your phone.")
                }

                Section("Ask about") {
                    Row(symbol: "brain", title: "What it knows") {
                        onPick(.ask("What do you actually know about my brand?"))
                    }
                    Row(symbol: "lightbulb", title: "This week") {
                        onPick(.ask("What should I post about this week?"))
                    }
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await session.refreshConnectedProviders()
                await session.refreshConnectable()
            }
        }
    }

    /// Says what making a video would actually use, so somebody is not offered
    /// a button that cannot do anything.
    private var makeDetail: String {
        let makers = session.connectedProviders.filter {
            $0.isHealthy && $0.capabilities.contains("video_generation")
        }
        guard !makers.isEmpty else { return "Connect a generator first" }
        let models = makers.reduce(0) { $0 + $1.modelCount }
        return "\(models) model\(models == 1 ? "" : "s") available"
    }
}

// MARK: - Rows

private struct Row: View {
    let symbol: String
    let title: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
            }
        }
    }
}

/// A provider that is connected, and what it can do.
///
/// Shows capabilities rather than a checkmark. "Connected" says the plumbing
/// worked; "3 models · video, image" says what it bought you, and that is the
/// question somebody actually has.
private struct ConnectedRow: View {
    let provider: ProviderConnection
    let action: () -> Void

    private var tint: Color {
        if !provider.isHealthy { return .orange }
        return provider.modelCount == 0 ? .orange : .green
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: provider.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.providerName).foregroundStyle(.primary)
                    Text(provider.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !provider.capabilities.isEmpty {
                        Text(provider.capabilities.map(readable).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readable(_ capability: String) -> String {
        capability
            .replacingOccurrences(of: "_generation", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }
}
