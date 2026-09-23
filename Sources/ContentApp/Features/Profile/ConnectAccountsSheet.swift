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

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

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
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Platform.allCases) { platform in
                            PlatformTile(
                                platform: platform,
                                connection: session.connection(for: platform),
                                isOpening: opening == platform
                            ) {
                                connect(platform)
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
            .background(Theme.canvas)
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
private struct PlatformTile: View {
    let platform: Platform
    let connection: PlatformConnection?
    let isOpening: Bool
    let choose: () -> Void

    private var isConnected: Bool { connection != nil }

    var body: some View {
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    Image(systemName: platform.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isConnected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .frame(width: 26, alignment: .leading)

                    Spacer(minLength: 0)

                    if isOpening {
                        ProgressView()
                    } else if isConnected {
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

                // The handle once it is connected, the invitation before.
                Text(connection?.label ?? "Tap to connect")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape.fill(isConnected ? AnyShapeStyle(Theme.accent.opacity(0.10)) : AnyShapeStyle(Theme.surface))
                    .overlay(shape.strokeBorder(isConnected ? Theme.accent : .clear, lineWidth: 1.5))
            }
            .scaleEffect(isConnected ? 0.98 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isConnected || isOpening)
        .animation(.snappy(duration: 0.2), value: isConnected)
        .accessibilityLabel(isConnected ? "\(platform.networkName), connected" : "Connect \(platform.networkName)")
        .accessibilityAddTraits(isConnected ? [.isSelected, .isButton] : .isButton)
    }
}
