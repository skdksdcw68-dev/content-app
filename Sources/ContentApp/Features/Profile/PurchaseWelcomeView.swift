import SwiftUI

/// What follows a purchase: a moment that says it worked, and what they have
/// now.
///
/// Netro, 18 Oct 2026: after Subscribe the paywall "is just spinning around
/// instead of showing me a welcome to pro screen", and "my reward was a good
/// animation". The spinner was the paywall waiting on `verify-purchase`, which
/// took 53 seconds on his sandbox purchase that day. Apple has already
/// confirmed the transaction on the phone by the time `purchase()` returns
/// `.verified`, so this opens at once and the server catches up behind it:
/// the plan's own numbers fill in when they arrive.
struct PurchaseWelcomeView: View {
    let tier: Tier
    /// What the plan includes, the same lines the paywall listed.
    let features: [String]
    /// This month's usage, once the server has the purchase.
    let standing: CreditsStanding?
    /// The server has the purchase (the plan shows as paid).
    let confirmed: Bool
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var celebrated = 0

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            if !reduceMotion {
                ConfettiBurst()
                    .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(Theme.onAccent, Theme.accent)
                    .symbolRenderingMode(.palette)
                    .symbolEffect(.bounce, value: celebrated)
                    .scaleEffect(shown ? 1 : 0.4)
                    .opacity(shown ? 1 : 0)
                    .accessibilityHidden(true)

                Text("Welcome to Autocast \(tier.name)")
                    .font(.system(size: 30, weight: .heavy))
                    .multilineTextAlignment(.center)
                    .padding(.top, 22)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 12)

                Text("You're all set. Here's what you have now.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .opacity(shown ? 1 : 0)
                    .offset(y: shown ? 0 : 12)

                VStack(alignment: .leading, spacing: 16) {
                    usageRow
                    ForEach(Array(features.enumerated()), id: \.offset) { index, line in
                        WelcomeRow(symbol: symbol(for: line), text: line)
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown ? 0 : 10)
                            .animation(.smooth(duration: 0.45).delay(0.25 + Double(index) * 0.07), value: shown)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, 28)

                Spacer(minLength: 24)

                Button {
                    onDone()
                } label: {
                    Text("Start creating")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(RemiFilledButtonStyle())
                .controlSize(.large)
                .opacity(shown ? 1 : 0)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .sensoryFeedback(.success, trigger: celebrated)
        .task {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { shown = true }
            celebrated += 1
        }
    }

    /// The month, from the server once it has the purchase. Until then a quiet
    /// line, never a spinner in the way of the moment.
    @ViewBuilder
    private var usageRow: some View {
        if confirmed, let standing, standing.allowance > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label {
                        Text("\(UsageFormat.percent(standing.percentLeft)) of this month")
                            .font(.body.weight(.semibold))
                    } icon: {
                        Image(systemName: "chart.bar.fill")
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer(minLength: 8)
                    if let resets = standing.resets {
                        Text("fills up \(resets.formatted(.dateTime.month(.abbreviated).day()))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: standing.fractionLeft)
                    .tint(Theme.proGreen)
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Setting up your plan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity)
        }
    }

    /// An icon that says what the line is about, read from the line itself:
    /// the plans list different things in a different order, and an icon by
    /// position put a calendar beside the models.
    private func symbol(for line: String) -> String {
        let words = line.lowercased()
        if words.contains("usage") { return "gauge.with.dots.needle.67percent" }
        if words.hasPrefix("everything in") { return "checkmark.circle" }
        if words.contains("model") { return "film.stack" }
        if words.contains("days ahead") { return "calendar" }
        if words.contains("account") { return "person.2" }
        return "sparkles"
    }
}

private struct WelcomeRow: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
        }
    }
}

/// A one-off burst of confetti from the top third of the screen, gone in
/// about three seconds. Drawn in a Canvas: seventy rectangles under gravity,
/// no images, nothing kept running once it has fallen.
struct ConfettiBurst: View {
    private struct Piece {
        let angle: Double
        let speed: Double
        let spin: Double
        let delay: Double
        let size: CGSize
        let color: Color
    }

    @State private var start = Date()
    @State private var done = false
    @State private var pieces: [Piece] = (0..<70).map { _ in
        let colors: [Color] = [Theme.accent, Theme.proGreen, .yellow, .pink, .orange, .cyan]
        return Piece(
            angle: -Double.pi / 2 + Double.random(in: -1.15...1.15),
            speed: Double.random(in: 380...780),
            spin: Double.random(in: -9...9),
            delay: Double.random(in: 0...0.18),
            size: CGSize(width: Double.random(in: 6...10), height: Double.random(in: 10...16)),
            color: colors.randomElement() ?? .yellow
        )
    }

    private let lifetime = 3.0
    private let gravity = 900.0

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: done)) { context in
            let elapsed = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.28)
                for piece in pieces {
                    let t = elapsed - piece.delay
                    guard t > 0, t < lifetime else { continue }
                    let x = origin.x + cos(piece.angle) * piece.speed * t
                    let y = origin.y + sin(piece.angle) * piece.speed * t + 0.5 * gravity * t * t
                    var layer = canvas
                    layer.opacity = max(0, 1 - t / lifetime)
                    layer.translateBy(x: x, y: y)
                    layer.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(x: -piece.size.width / 2, y: -piece.size.height / 2,
                                      width: piece.size.width, height: piece.size.height)
                    layer.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(piece.color))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            try? await Task.sleep(for: .seconds(lifetime + 0.3))
            done = true
        }
    }
}
