import SwiftUI

/// What a screen shows instead of itself while no account is connected.
///
/// Abel, 29 Sep 2026: "there is a chart page, analytics, you, and a plus
/// icon. Those three must have a connection, at least with one connector."
/// Analytics is about an account's numbers, Create is about making things to
/// post, and You is where the account lives -- none of them means anything
/// without one, and each used to show a full screen of nothing.
///
/// One gate for all three, built from the connect sheet's own tiles, so the
/// first thing on the screen is the thing to do: tap a network, sign in, and
/// the screen behind it fills. No sheet to open first.
///
/// It is shown only when the accounts have been READ and none is working
/// (`AppSession.needsAccount`). A read that has not come back, or failed,
/// must not tell somebody who is connected to connect.
struct ConnectGate: View {
    @Environment(AppSession.self) private var session

    /// The picture at the top, by asset name.
    let art: String
    let title: String
    let detail: String

    /// Which network is opening its sign-in, so only that tile spins.
    @State private var opening: Platform?

    /// Two to a row, and an odd last one takes the whole row.
    private static let rows: [[Platform]] = stride(from: 0, to: Platform.allCases.count, by: 2).map {
        Array(Platform.allCases[$0..<min($0 + 2, Platform.allCases.count)])
    }

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                EmptyArt(name: art, size: 110)
                Text(title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(Self.rows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(row) { platform in
                            PlatformTile(
                                platform: platform,
                                connection: session.connection(for: platform),
                                isOpening: opening == platform
                            ) {
                                connect(platform)
                            }
                        }
                    }
                }
            }

            Text("Instagram needs a Business or Creator account. Nothing goes out until you approve it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
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
