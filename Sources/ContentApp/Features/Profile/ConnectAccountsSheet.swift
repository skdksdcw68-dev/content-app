import SwiftUI

/// Where it posts, as a sheet: the same screen onboarding uses to ask what
/// you're promoting and where you post, rather than a settings list.
///
/// Abel, 23 Sep 2026: "the ui for the connect account [should be like] the
/// onboarding place -- the one which lets you choose the category and post".
/// So it is that screen's parts, reused rather than imitated: the title and
/// subtitle at the top, the same two-column field of tiles, the same accent
/// border on the ones already chosen. A connected account is a tile that has
/// been picked and says who it is; tapping an unconnected one opens the
/// network's own sign-in.
///
/// Opened from wherever an account is missing -- Home, Create, Analytics --
/// instead of sending somebody to Profile to hunt for it.
struct ConnectAccountsSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Which one is opening its sign-in right now, so only that tile spins.
    @State private var opening: Platform?

    /// The networks, two to a row.
    private static let rows: [[Platform]] = stride(from: 0, to: Platform.allCases.count, by: 2).map {
        Array(Platform.allCases[$0..<min($0 + 2, Platform.allCases.count)])
    }

    private var connectedCount: Int {
        Platform.allCases.filter { session.connection(for: $0) != nil }.count
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Where should it post?")
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("Pick an account to connect. Nothing goes out until you approve it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                ScrollView {
                    // Two to a row, and an odd last one takes the whole row
                    // rather than sitting next to a hole. There are three
                    // networks, so this is not hypothetical -- it is the same
                    // stranded tile Abel objected to in the questions.
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
                    .padding(.horizontal, 20)

                    Text("Instagram needs a Business or Creator account. You can connect more later in Profile.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 28)
                        .padding(.top, 18)
                }
                .scrollIndicators(.hidden)

                OnboardingButton(
                    title: connectedCount > 0 ? "Done" : "Not now",
                    tint: connectedCount > 0 ? Theme.accent : Color.secondary
                ) {
                    dismiss()
                }
                .padding(.top, 10)
                .animation(.snappy(duration: 0.2), value: connectedCount)
            }
            .padding(.top, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").fontWeight(.semibold)
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
    }

    private func connect(_ platform: Platform) {
        guard session.connection(for: platform) == nil, opening == nil else { return }
        opening = platform
        Task {
            await session.connect(platform)
            opening = nil
        }
    }
}

/// One network, shaped exactly like an onboarding answer: symbol, name, and
/// the accent border once it is yours.
///
/// Shared with the series flow's "where should it post?" step, which used to
/// draw a row with a separate Connect pill beside it and looked like a form
/// (Abel, 24 Sep 2026: "on the connect page, bro i hate that"). One tile does
/// both jobs: not connected, tapping opens the network's sign-in; connected,
/// tapping picks it.
struct PlatformTile: View {
    let platform: Platform
    let connection: PlatformConnection?
    let isOpening: Bool
    /// Nil on the plain connect sheet, where there is nothing to choose. Set
    /// in the series flow, where a connected account is also picked or not.
    var isChosen: Bool?
    let choose: () -> Void

    private var isConnected: Bool { connection != nil }
    /// Filled in when it is yours, or when it is yours AND picked.
    private var isLit: Bool { isChosen ?? isConnected }

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    // The network's own mark, so the row is recognised rather
                    // than read (Abel, 25 Sep 2026).
                    platform.logo.view
                        .frame(width: 26, height: 26)
                        .saturation(isConnected ? 1 : 0.9)

                    Spacer(minLength: 0)

                    if isOpening {
                        ProgressView()
                    } else if isLit {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .transition(.opacity)
                    }
                }

                Text(platform.networkName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The account itself once it is yours -- the picture and the
                // handle, not the word "Connected" (Abel, 25 Sep 2026: "if the
                // user connected his social media account, show the profile
                // exactly right there"). The avatar was already being fetched
                // and drawn on three other screens; this tile just never used
                // it.
                HStack(spacing: 6) {
                    if let avatar = connection?.avatarURL {
                        AsyncImage(url: avatar) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.track)
                        }
                        .frame(width: 18, height: 18)
                        .clipShape(Circle())
                    }
                    Text(connection?.label ?? (isOpening ? "Opening…" : "Tap to connect"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(isLit ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(isLit ? Theme.accent : .clear, lineWidth: 1.5))
            }
            .scaleEffect(isLit ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isConnected || isOpening)
        .animation(.snappy(duration: 0.2), value: isConnected)
        .accessibilityLabel(isConnected ? "\(platform.networkName), connected" : "Connect \(platform.networkName)")
        .accessibilityAddTraits(isConnected ? [.isSelected, .isButton] : .isButton)
    }
}
