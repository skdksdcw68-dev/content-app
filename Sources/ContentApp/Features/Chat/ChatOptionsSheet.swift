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
        /// Flip the composer into the generator, worn as a tag -- not words
        /// typed into the field (Abel, 26 Sep 2026: "let it be like a tag or
        /// a different tag not a text actually").
        case create(GenerateChoices.Mode)
        case planMonth
        case ask(String)
        case attachPhoto
        case connect(String)
        case reconnect(ProviderConnection)
        case refresh(ProviderConnection)
        case disconnect(ProviderConnection)
    }

    /// The connection whose options are open.
    @State private var choosing: ProviderConnection?

    @Environment(AppSession.self) private var session
    /// Opened from the video page rather than the chat. The list then holds
    /// only what belongs to making a video -- "Plan 30 days", "Look into
    /// something" and "What is working" are chat errands and have no business
    /// on a screen whose single job is a video (Abel, 25 Sep 2026: "when you
    /// hit the plus icon it is showing the same as the chat").
    var makingVideo = false
    let onPick: (Action) -> Void

    var body: some View {
        // 🔴 Remi's plus sheet, brought across on its owner's own instruction.
        // Abel, 26 Sep 2026: "the + isnt as remi app side admin panel chat am
        // sure, brother it looks bad."
        //
        // What Remi's gets right and a grouped List got wrong: it is a
        // LAUNCHER, not a settings page. Two big tiles for the two things
        // somebody actually came for, one quiet card of rows under them, and
        // the conversation still visible above the sheet. No navigation bar,
        // no section headers, no full screen.
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                tile(symbol: "video", title: "Video") { onPick(.create(.video)) }
                tile(symbol: "photo", title: "Image") { onPick(.create(.image)) }
            }

            VStack(spacing: 0) {
                row(symbol: "paperclip", title: "Attach a photo",
                    detail: "Use it as a reference, or ask about it") { onPick(.attachPhoto) }
                Divider().padding(.leading, 62)
                row(symbol: "calendar", title: "Plan 30 days",
                    detail: "Writes and schedules a month at once") { onPick(.planMonth) }
                Divider().padding(.leading, 62)
                row(symbol: "magnifyingglass", title: "Look into something",
                    detail: "Keeps working after you close the app") { onPick(.ask("Research ")) }
                Divider().padding(.leading, 62)
                row(symbol: "chart.line.uptrend.xyaxis", title: "What's working",
                    detail: "Reads your own numbers back") { onPick(.ask("What's working in my recent posts?")) }
            }
            .background(Color.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            // The generators, one row each, still one tap from here -- the
            // choices dialog is unchanged underneath.
            if !session.connectedProviders.isEmpty || !session.connectable.isEmpty {
                VStack(spacing: 0) {
                    ForEach(session.connectedProviders) { provider in
                        ConnectedRow(provider: provider) { choosing = provider }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if provider.id != session.connectedProviders.last?.id || !session.connectable.isEmpty {
                            Divider().padding(.leading, 62)
                        }
                    }
                    ForEach(session.connectable) { provider in
                        row(symbol: "person.crop.circle.badge.plus",
                            title: provider.action, detail: provider.how) { onPick(.connect(provider.slug)) }
                    }
                }
                .background(Color.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Style.gutter)
        .padding(.top, 20)
        .background(Color.canvas.ignoresSafeArea())
        .task {
            await session.refreshConnectedProviders()
            await session.refreshConnectable()
        }
        .confirmationDialog(
                choosing?.providerName ?? "",
                isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                titleVisibility: .visible,
                presenting: choosing
            ) { provider in
                if provider.isHealthy {
                    Button("Check what it offers") { onPick(.refresh(provider)) }
                }
                Button(provider.isPastedKey ? "Sign in instead" : "Sign in again") {
                    onPick(.reconnect(provider))
                }
                Button("Disconnect", role: .destructive) { onPick(.disconnect(provider)) }
        } message: { provider in
            Text("\(provider.door) · \(provider.summary)")
        }
        // Remi's height: the two tiles, the rows, and the conversation still
        // in view above it. Pulls to full only when the generator list needs
        // the room.
        .presentationDetents([.height(470), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func tile(symbol: String, title: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Color.primary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(Color.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(SoftPressStyle())
    }

    private func row(symbol: String, title: String, detail: String, tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.06))
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.primary)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.primary)
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
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
                    Text("\(provider.door) · \(provider.summary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !provider.capabilities.isEmpty {
                        Text(provider.capabilities.map(readable).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "ellipsis.circle")
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
