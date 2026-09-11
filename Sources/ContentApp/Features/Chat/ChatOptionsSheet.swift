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
        case attachPhoto
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
                    // Both end in a space: they want the rest typed -- what
                    // the video is of -- rather than sending a request with
                    // nothing in it to make.
                    Row(
                        symbol: "video",
                        title: "Make a video",
                        detail: makeDetail(for: "video_generation")
                    ) { onPick(.ask("Make a video of ")) }

                    Row(
                        symbol: "photo",
                        title: "Make an image",
                        detail: makeDetail(for: "image_generation")
                    ) { onPick(.ask("Make an image of ")) }

                    Row(
                        symbol: "paperclip",
                        title: "Attach a photo",
                        detail: "Use it as a reference, or ask about it"
                    ) { onPick(.attachPhoto) }

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

            }
            // Denser than a default List on purpose. This sheet is a launcher:
            // somebody opens it, taps one thing, and it goes. Default row
            // height and section spacing made it a full-screen page, which is
            // why it opened covering the conversation it was launched from.
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 40)
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await session.refreshConnectedProviders()
                await session.refreshConnectable()
            }
        }
        // Opens at a compact height with the conversation still visible above
        // it, and pulls up to full when there is more to scroll. The sheet had
        // no detents at all before, so it always opened full-screen.
        .presentationDetents([.height(540), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(24)
    }

    /// Says what making one would actually use, so somebody is not offered a
    /// button that cannot do anything. Counts providers rather than models:
    /// the model count spans every capability a connection has, and "40
    /// models" under "Make an image" would be a number about video.
    private func makeDetail(for capability: String) -> String {
        let makers = session.connectedProviders.filter {
            $0.isHealthy && $0.capabilities.contains(capability)
        }
        guard let first = makers.first else { return "Connect a generator first" }
        return makers.count == 1 ? "With \(first.providerName)" : "With \(makers.count) providers"
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: symbol)
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
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
