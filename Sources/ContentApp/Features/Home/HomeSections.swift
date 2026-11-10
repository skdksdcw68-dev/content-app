import SwiftUI

/// The pieces of Home as the approved mockup draws it ("Home and sign-up
/// redesign", Abel, 10 Nov 2026): a big section title with a link on the right,
/// tall "Trending today" posters whose words light up one after another, and
/// the quiet "Post for me every day" row at the bottom.

// MARK: - Section header

/// "Trending today" (with its live red dot), "Your videos", and so on: 22 pt
/// bold, and a small purple link at the right when there is somewhere to go.
struct HomeHeader: View {
    let title: String
    var live = false
    var trailing: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                if live { LiveDot() }
            }
            Spacer(minLength: 8)
            if let trailing {
                Button(action: action) {
                    Text(trailing)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The small red dot that breathes beside "Trending today".
private struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color(red: 1, green: 0.27, blue: 0.23))
            .frame(width: 7, height: 7)
            .scaleEffect(pulse ? 1.7 : 1)
            .opacity(pulse ? 0.35 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Trending today

/// What is trending, looked up once a day per country by the `trends` function
/// (the same cards Explore shows), as tall posters. Hidden when there is
/// nothing to show, never an empty heading.
struct HomeTrendingSection: View {
    @Environment(AppSession.self) private var session

    @State private var trends: [TrendCard] = []
    @State private var loading = true

    var body: some View {
        if loading || !trends.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HomeHeader(title: "Trending today", live: true, trailing: "See all") {
                    session.push(.chatOpening("What's trending right now for creators on TikTok and Reels? Pick the best one for me and write the post."))
                }
                row
                    .padding(.top, 12)
            }
            .task { await load() }
        } else {
            Color.clear.frame(height: 0).task { await load() }
        }
    }

    private var row: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                if loading {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.track)
                            .frame(width: 244, height: 348)
                            .breathing()
                    }
                } else {
                    ForEach(Array(trends.prefix(5).enumerated()), id: \.element.id) { index, trend in
                        Button {
                            session.push(.chatOpening("Make me a post on this trend: \(trend.title). \(trend.idea)"))
                        } label: {
                            TrendPosterCard(trend: trend, rank: index + 1)
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
            }
            // Runs to the screen's edges while the gutter stays on the rest.
            .padding(.horizontal, Style.gutter)
        }
        .padding(.horizontal, -Style.gutter)
    }

    private func load() async {
        guard trends.isEmpty else { return }
        let found = await session.trends()
        withAnimation(.snappy(duration: 0.3)) {
            trends = found
            loading = false
        }
    }
}

/// One trend as a poster, 244 x 348: its name in big capitals lighting up line
/// by line, a rank and a kind badge, the reason, and "Make this".
private struct TrendPosterCard: View {
    let trend: TrendCard
    let rank: Int

    private static let backgrounds: [Color] = [
        Color(red: 0.106, green: 0.078, blue: 0.188),
        Color(red: 0.059, green: 0.133, blue: 0.188),
        Color(red: 0.169, green: 0.090, blue: 0.063),
    ]

    /// The title in capitals, over at most three lines.
    private var lines: [String] {
        let words = trend.title.uppercased().split(separator: " ").prefix(7).map(String.init)
        guard !words.isEmpty else { return [] }
        let per = Int((Double(words.count) / 3).rounded(.up))
        return stride(from: 0, to: words.count, by: per).map {
            words[$0..<min($0 + per, words.count)].joined(separator: " ")
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Self.backgrounds[(rank - 1) % Self.backgrounds.count]

            PulsingLines(lines: lines)
                .padding(.horizontal, 18)
                .frame(width: 244)
                .offset(y: 96)

            LinearGradient(colors: [.black.opacity(0.88), .black.opacity(0)], startPoint: .bottom, endPoint: .top)
                .frame(height: 190)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)

            HStack(spacing: 6) {
                Text("#\(rank)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white, in: Capsule())
                Text(trend.kind.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            .padding(14)

            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                Text(trend.title)
                    .font(.system(size: 19, weight: .bold))
                    .tracking(-0.2)
                    .lineLimit(2)
                Text(trend.why)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Image(systemName: "play.fill").font(.system(size: 13))
                    Text("Make this").font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.white, in: Capsule())
                .padding(.top, 6)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(width: 244, height: 348, alignment: .bottomLeading)
        }
        .frame(width: 244, height: 348)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Number \(rank), \(trend.kind): \(trend.title). Make this")
    }
}

/// The poster's words: each line rises to full strength, holds, then fades
/// back, a little after the one above (the mockup's `ppWord`, 2.4 s a round).
/// Still and fully lit under Reduce Motion.
private struct PulsingLines: View {
    let lines: [String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            VStack(spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.system(size: 26, weight: .heavy))
                        .tracking(-0.3)
                        .lineSpacing(0)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .opacity(reduceMotion ? 1 : opacity(at: t, delay: Double(index) * 0.6))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func opacity(at time: Double, delay: Double) -> Double {
        let round = 2.4
        let raw = (time - delay).truncatingRemainder(dividingBy: round)
        let p = (raw < 0 ? raw + round : raw) / round
        if p < 0.08 { return 0.28 + 0.72 * p / 0.08 }
        if p < 0.30 { return 1 }
        return 1 - 0.72 * (p - 0.30) / 0.70
    }
}

// MARK: - Post for me

/// "Post for me every day", with Start: a calendar, two lines, a small pill,
/// under a hairline.
struct PostForMeRow: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Post for me every day")
                        .font(.system(size: 17, weight: .semibold))
                    Text("A new video daily. You see it first.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: start) {
                    Text("Start")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .background(Color.raised, in: Capsule())
                }
                .buttonStyle(SoftPressStyle())
            }
            .padding(.top, 18)
        }
    }
}
