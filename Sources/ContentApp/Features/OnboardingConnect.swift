import SwiftUI

/// Connecting an account, and connecting a generator.
///
/// One screen for both, because they are the same screen: a list of things you
/// could link, each saying what it is for and whether it is linked yet.
///
/// The reference draws five platforms and five video engines, all of them
/// clickable. Four of each do not exist here, and a Connect button that opens
/// nothing is the fastest way to teach somebody the buttons are decorative. So
/// what is real is real, and what is coming says so and cannot be pressed.
struct OnboardingConnect: View {
    enum Kind { case account, generator }

    let kind: Kind

    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(rows) { row in
                        ConnectRow(row: row) { act(on: row) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .background(Theme.canvas)
    }

    // MARK: - What is on the screen

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = session.onboarding.progress {
                ProgressView(value: progress)
                    .tint(Theme.accent)
                    .padding(.bottom, 2)
            }

            Text(kind == .account ? "Connect your account" : "Connect a video engine")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)

            Text(kind == .account
                 ? "Autocast needs permission to post for you. Nothing goes out without your approval."
                 : "Where the videos come from. You bring your own key, and you are billed by them for what it makes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button { session.onboardingNext() } label: {
                Text(anythingConnected ? "Continue" : "Skip for now")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .tint(anythingConnected ? Theme.accent : Color.secondary)
            .controlSize(.large)

            if !anythingConnected {
                Text(kind == .account
                     ? "You can connect it later under You."
                     : "Without one you add your own videos, which works fine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var anythingConnected: Bool {
        kind == .account ? !session.connections.isEmpty : session.hasWorkingGenerator
    }

    // MARK: - The rows

    private var rows: [ConnectRow.Model] {
        switch kind {
        case .account:
            return [
                .init(
                    id: "tiktok",
                    title: "TikTok",
                    detail: "Post short video to your account",
                    symbol: "music.note",
                    logo: .tiktok,
                    avatar: session.connections.first?.avatarURL,
                    state: session.connections.isEmpty
                        ? .available
                        : (session.connections.first?.isHealthy == true ? .connected : .needsAttention),
                    connectedAs: session.connections.first?.label
                ),
                .init(
                    id: "reels",
                    title: "Instagram Reels",
                    detail: "Waiting on Meta's review",
                    symbol: "camera",
                    logo: .instagram,
                    state: .soon
                ),
                .init(
                    id: "shorts",
                    title: "YouTube Shorts",
                    detail: "Waiting on a quota increase",
                    symbol: "play.rectangle",
                    logo: .youtube,
                    state: .soon
                ),
            ]

        case .generator:
            let generator = session.generators.first
            // A Higgsfield connection made by signing in counts as much as a
            // pasted key -- more, since it is now the default way in.
            let signedIn = session.connectedProviders.first { $0.providerSlug == "higgsfield" }
            return [
                .init(
                    id: "higgsfield",
                    title: "Higgsfield",
                    detail: "Makes the video from the plan's own description",
                    symbol: "wand.and.stars",
                    // ⚠️ No drawn logo, and that is deliberate rather than
                    // unfinished. TikTok, Instagram and YouTube have marks
                    // built from squares and circles that anybody would
                    // recognise; Higgsfield's is not something to reproduce
                    // from memory, and a wrong logo is worse than an honest
                    // letter. Swap this for their real asset when you have it.
                    mark: .init(letter: "H", tint: .indigo),
                    state: signedIn.map { $0.isHealthy ? .connected : .needsAttention }
                        ?? (generator == nil ? .available : (generator?.isWorking == true ? .connected : .needsAttention)),
                    connectedAs: signedIn.map(\.summary)
                        ?? (generator?.isWorking == true ? "Key verified" : generator?.statusLine)
                ),
                .init(
                    id: "own",
                    title: "Your own videos",
                    detail: "Always available. Pick from your camera roll.",
                    symbol: "video",
                    mark: .init(letter: "V", tint: .teal),
                    state: .always
                ),
                .init(
                    id: "more",
                    title: "More engines",
                    detail: "One provider at a time until this one is proven",
                    symbol: "square.stack.3d.up",
                    mark: .init(letter: "+", tint: .gray),
                    state: .soon
                ),
            ]
        }
    }

    private func act(on row: ConnectRow.Model) {
        switch (kind, row.state) {
        case (.account, .available), (.account, .needsAttention):
            Task { await session.connectTikTok() }
        case (.generator, .available), (.generator, .needsAttention):
            // Sign in to Higgsfield, not paste a key. The key sheet was the
            // only way in before MCP connection existed, and it asked somebody
            // to find a developer dashboard and copy two strings.
            Task { await session.connectProvider("higgsfield") }
        default:
            break
        }
    }
}

// MARK: - One row

struct ConnectRow: View {
    struct Model: Identifiable {
        enum State { case available, connected, needsAttention, soon, always }

        /// A lettermark: one letter in the service's own colour.
        ///
        /// Still here, but no longer the answer for the platforms. It is what
        /// a service gets when there is no mark of theirs anybody would
        /// recognise -- see `logo` below.
        struct Mark {
            let letter: String
            let tint: Color
        }

        let id: String
        let title: String
        let detail: String
        let symbol: String
        /// The real thing, drawn. Takes precedence over `mark`.
        var logo: BrandLogo?
        var mark: Mark?
        var avatar: URL?
        let state: State
        var connectedAs: String?

        var isActionable: Bool { state == .available || state == .needsAttention }
    }

    let row: Model
    let act: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Badge(row: row)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(row.state == .soon ? Color.secondary : Color.primary)

                Text(row.connectedAs ?? row.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(14)
        .background {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape.fill(Theme.surface)
                .overlay(shape.strokeBorder(row.state == .connected ? Color.green.opacity(0.5) : .clear, lineWidth: 1.5))
        }
        .contentShape(Rectangle())
        .onTapGesture { if row.isActionable { act() } }
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .connected:
            // No word. The row already shows the account handle underneath the
            // title, which says "connected" better than the word does, and a
            // green pill reading CONNECTED beside it was the loudest thing on a
            // screen whose whole job is to be scanned.
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))

        case .needsAttention:
            Button("Reconnect", action: act)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(.orange)

        case .available:
            Button("Connect", action: act)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)

        case .always:
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

        case .soon:
            Text("Soon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.softAccent, in: Capsule())
        }
    }
}

/// The picture beside a row.
///
/// Once an account is connected this is the creator's own avatar, which is the
/// difference between "an account is linked" and "yours is". Before that it is
/// the platform's lettermark in its own colour, and where there is neither, the
/// same placeholder Contacts uses for somebody with no photo.
private struct Badge: View {
    let row: ConnectRow.Model

    var body: some View {
        Group {
            if let avatar = row.avatar {
                AsyncImage(url: avatar) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    if let logo = row.logo { logo.view } else { lettermark }
                }
            } else if let logo = row.logo {
                logo.view
            } else if row.mark != nil {
                lettermark
            } else {
                ZStack {
                    Circle().fill(Theme.softAccent)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .opacity(row.state == .soon ? 0.45 : 1)
    }

    @ViewBuilder
    private var lettermark: some View {
        if let mark = row.mark {
            ZStack {
                Circle().fill(mark.tint)
                Text(mark.letter)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
    }
}
