import SwiftUI

/// What you get for paying, and what it costs.
///
/// Nothing behind this button charges anybody yet -- there is no StoreKit
/// product, no subscription, no receipt. It is the screen the offer will need,
/// wired to real copy so the words can be argued about before the plumbing is
/// built, and it says plainly at the bottom that it is not live. A paywall that
/// pretends to take money is the one screen you cannot ship half-finished.
struct UpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Header()

                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Autocast Pro")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text("A month of posts, made and published without you")
                                .font(.title2.bold())
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 18) {
                            ForEach(Perk.all) { perk in
                                PerkRow(perk: perk)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }
            }
            .background(Theme.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                // Nothing to call yet. Left inert rather than wired to a
                // half-finished purchase -- the one place a stub must not
                // pretend is the one that takes money.
            } label: {
                Text("Coming soon")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(true)

            Text("Not on sale yet. Everything here works today on your own keys — you pay TikTok nothing and your generator directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

// MARK: - The header

/// The gradient at the top.
///
/// A `MeshGradient` rather than an exported image: it is four colours and a
/// grid, it scales to any screen without a 2x and 3x, it costs nothing in the
/// bundle, and it can be made to move. An image would be a fixed rectangle that
/// has to be re-exported the first time the wording changes.
private struct Header: View {
    @State private var shifted = false

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    .init(0, 0),   .init(0.5, 0),   .init(1, 0),
                    .init(0, 0.5), .init(shifted ? 0.6 : 0.4, 0.5), .init(1, 0.5),
                    .init(0, 1),   .init(0.5, 1),   .init(1, 1),
                ],
                colors: [
                    .purple, .indigo, .blue,
                    .pink, .purple, .indigo,
                    .orange, .pink, .purple,
                ]
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
                    shifted = true
                }
            }

            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                Text("Autocast Pro")
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
            }
            // White on the gradient in both schemes: the mesh is saturated
            // either way, so this is one of the few places a literal colour is
            // the correct answer rather than a lazy one.
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
        .frame(height: 260)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

// MARK: - What you get

private struct Perk: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String

    static let all: [Perk] = [
        .init(
            id: "plan",
            symbol: "calendar",
            title: "A month at a time",
            detail: "Thirty posts written, timed and themed in one go."
        ),
        .init(
            id: "make",
            symbol: "wand.and.stars",
            title: "It makes the videos",
            detail: "From the plan's own description of the shot."
        ),
        .init(
            id: "auto",
            symbol: "paperplane",
            title: "Posts on its own",
            detail: "Approve once. It goes out on time with the app closed."
        ),
        .init(
            id: "platforms",
            symbol: "square.stack.3d.up",
            title: "Every account at once",
            detail: "TikTok now. Reels and Shorts as each approval lands."
        ),
        .init(
            id: "numbers",
            symbol: "chart.line.uptrend.xyaxis",
            title: "Numbers that feed back",
            detail: "What worked shapes what it plans next."
        ),
    ]
}

private struct PerkRow: View {
    let perk: Perk

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: perk.symbol)
                .font(.system(size: 18, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.accent)
                .frame(width: 26, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(perk.title)
                    .font(.body.weight(.semibold))
                Text(perk.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
