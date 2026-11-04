import SwiftUI

/// What a screen shows instead of itself while no account is connected.
///
/// Abel, 29 Sep 2026: "there is a chart page, analytics, you, and a plus
/// icon. Those three must have a connection, at least with one connector."
/// Abel, 4 Nov 2026 (mockup screen 8): the numbers it will show sit faded
/// behind "Your numbers show here", then one row per network with its own
/// Connect, and a line saying it only reads. Connect opens `ConnectSheet`
/// first, which says what is and is not seen.
///
/// It is shown only when the accounts have been READ and none is working
/// (`AppSession.needsAccount`). A read that has not come back, or failed,
/// must not tell somebody who is connected to connect.
struct ConnectGate: View {
    @Environment(AppSession.self) private var session

    let art: String
    let title: String
    let detail: String

    @State private var asking: Platform?
    @State private var opening: Platform?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if art == "empty-analytics" {
                LockedNumbers()
            } else {
                EmptyArt(name: art, size: 110)
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Platform.allCases) { platform in
                    ConnectRow(
                        platform: platform,
                        connection: session.connection(for: platform),
                        isOpening: opening == platform
                    ) { asking = platform }
                    if platform != Platform.allCases.last {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
            }

            Label("Read only. Nothing is posted until you approve it.", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $asking) { platform in
            ConnectSheet(platform: platform) { connect(platform) }
        }
    }

    private func connect(_ platform: Platform) {
        guard opening == nil else { return }
        opening = platform
        Task {
            await session.connect(platform)
            opening = nil
        }
    }
}

/// One network: its mark, what it gives, and Connect -- or the account, once
/// it is yours.
struct ConnectRow: View {
    let platform: Platform
    let connection: PlatformConnection?
    let isOpening: Bool
    let onConnect: () -> Void

    private var isConnected: Bool { connection?.isHealthy == true }
    private var needsSignIn: Bool { connection != nil && !isConnected }

    private var line: String {
        if isConnected, let label = connection?.label { return label }
        if needsSignIn { return "Signed out · sign in again" }
        switch platform {
        case .tiktok: return "Views, followers, best hours"
        case .shorts: return "Shorts views and subscribers"
        case .reels:  return "Needs a Business or Creator account"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            platform.logo.view
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(platform.networkName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(needsSignIn ? Color.orange : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if isOpening {
                ProgressView()
            } else if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Connected")
            } else {
                Button(action: onConnect) {
                    Text(needsSignIn ? "Sign in" : "Connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityLabel("Connect \(platform.networkName)")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
    }
}

/// Before the network's own sign-in: what Postpilot will and won't see
/// (mockup screen 9).
struct ConnectSheet: View {
    let platform: Platform
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var sees: [String] {
        switch platform {
        case .tiktok: return ["See your public videos and their views", "See your follower count", "Post a video only when you tap Approve"]
        case .shorts: return ["See your Shorts and their views", "See your subscriber count", "Upload a Short only when you tap Approve"]
        case .reels:  return ["See your Reels and their views", "See your follower count", "Post a Reel only when you tap Approve"]
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image("app-mark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    platform.logo.view
                        .frame(width: 56, height: 56)
                }
                .accessibilityHidden(true)
                Text("Connect \(platform.networkName)")
                    .font(.title2.bold())
                Text("So Postpilot can show your numbers and learn what works for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)

            VStack(spacing: 0) {
                ForEach(Array(sees.enumerated()), id: \.offset) { index, line in
                    permission(line, allowed: true)
                    Divider().padding(.leading, 44)
                }
                permission("Never sees your messages or password", allowed: false)
            }
            .background(PickKit.card)

            Spacer(minLength: 8)

            Button {
                dismiss()
                onContinue()
            } label: {
                Text("Continue with \(platform.networkName)")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Capsule().fill(Color.primary))
            }
            .buttonStyle(PressButtonStyle())

            Button("Not now") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Disconnect any time in Settings › Connections.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.visible)
    }

    private func permission(_ text: String, allowed: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(allowed ? Color.green : Color.secondary)
            Text(text)
                .font(.body)
                .foregroundStyle(allowed ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
    }
}

/// The numbers Analytics will show, faded, with "Your numbers show here" over
/// them -- what connecting buys, before anything is connected.
private struct LockedNumbers: View {
    private let heights: [CGFloat] = [30, 70, 40, 48, 34, 56, 28]

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(["Views", "Followers", "Engagement"], id: \.self) { name in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.caption).foregroundStyle(.secondary)
                        Text("—").font(.title3.bold())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
            }
            .opacity(0.45)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Theme.accent)
                        .frame(height: height)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 76, alignment: .bottom)
            .opacity(0.25)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
        }
        .overlay {
            Label("Your numbers show here", systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your numbers show here once an account is connected")
    }
}

/// In the chat, when an answer needs an account that is not connected
/// (mockup screen 10): the network's row with Connect, then, once it is
/// connected, its first reading as it happens -- and the question is asked
/// again so the answer arrives with its numbers.
struct ChatConnectCard: View {
    let platform: Platform
    /// Asks the question again once the account is read.
    let onConnected: () -> Void

    @Environment(AppSession.self) private var session
    @State private var asking = false
    @State private var opening = false
    @State private var reading: Reading = .idle

    private enum Reading: Equatable { case idle, account, done }

    private var connection: PlatformConnection? { session.connection(for: platform) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConnectRow(platform: platform, connection: connection, isOpening: opening) { asking = true }
                .padding(.horizontal, -14)

            if reading != .idle {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Reading your \(platform.networkName)")
                        .font(.subheadline.weight(.semibold))
                    step("Account and followers", done: reading == .done, live: reading == .account)
                    step("Your videos and their views", done: reading == .done, live: reading == .account)
                    step("What worked and what to post next", done: reading == .done, live: false)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
        }
        .animation(.snappy(duration: 0.25), value: reading)
        .sheet(isPresented: $asking) {
            ConnectSheet(platform: platform) { connect() }
        }
    }

    private func step(_ title: String, done: Bool, live: Bool) -> some View {
        HStack(spacing: 10) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if live {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "circle").foregroundStyle(.tertiary)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(done || live ? Color.primary : Color.secondary)
        }
    }

    private func connect() {
        guard !opening else { return }
        opening = true
        Task {
            await session.connect(platform)
            opening = false
            guard session.connection(for: platform)?.isHealthy == true else { return }
            reading = .account
            _ = await session.metrics()
            reading = .done
            onConnected()
        }
    }
}
