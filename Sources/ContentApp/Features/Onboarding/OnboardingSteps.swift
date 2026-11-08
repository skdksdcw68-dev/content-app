import SwiftUI

/// The quiet steps of first run, in Bevel's soft way: one thing on the page,
/// centred, lots of room (Abel, 8 Nov 2026): what is never done with their
/// information, and the ask for pings with a reason. No name is asked before
/// sign-up: App Review rejects it (5.1.1(v)), and Apple hands the name over.

extension View {
    /// A faint purple haze top right and grey bottom left, behind a page.
    func softGlassBackground() -> some View {
        background {
            ZStack {
                RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: UnitPoint(x: 0.9, y: 0.12), startRadius: 0, endRadius: 340)
                RadialGradient(colors: [Color.secondary.opacity(0.18), .clear], center: UnitPoint(x: 0.05, y: 0.92), startRadius: 0, endRadius: 340)
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Privacy

/// What is true about their data, said calmly, with a ring that fills over
/// three seconds while three lines tick in. Only claims that are true: the
/// videos and photos ARE stored on our server, so that is never said.
struct OnboardingPrivacyView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var ticked = 0
    @State private var locked = false

    private let lines: [(String, String)] = [
        ("Encrypted.", "Your data is encrypted, in transit and at rest."),
        ("Yours alone.", "Your videos and photos belong to you."),
        ("Delete any time.", "Delete your account and everything in it, any time."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(locked ? 1 : 0.95)
            }
            .frame(width: 110, height: 110)

            Text("Private by design")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 26)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.bounce, value: ticked > index)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.0).font(.subheadline.weight(.semibold))
                            Text(line.1).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .opacity(ticked > index ? 1 : 0)
                    .offset(y: ticked > index ? 0 : 8)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("We never sell or share your information.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .opacity(locked ? 1 : 0)

            Spacer(minLength: 0)

            OnboardingButton(title: "Continue") { session.onboardingNext(from: .privacy) }
                .disabled(!locked)
                .opacity(locked ? 1 : 0.4)
        }
        .softGlassBackground()
        .animation(.snappy(duration: 0.3), value: ticked)
        .animation(.snappy(duration: 0.3), value: locked)
        .task { await run() }
    }

    private func run() async {
        if reduceMotion {
            progress = 1
            ticked = lines.count
            locked = true
            return
        }
        withAnimation(.linear(duration: 3)) { progress = 1 }
        for step in 1...lines.count {
            try? await Task.sleep(for: .milliseconds(900))
            ticked = step
        }
        try? await Task.sleep(for: .milliseconds(500))
        locked = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - Pings

/// Asks for notifications with the reason, on a lock screen that shows what
/// they look like, and only brings up the system's question if the person
/// says yes here first.
struct OnboardingPingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0

    private let messages = [
        "Your video is ready.",
        "Posted to TikTok, Instagram and YouTube.",
        "Your video hit 48K views.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            lockScreen
                .padding(.horizontal, 36)
                .padding(.top, 8)

            Text("Get a ping when your video is ready")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 22)
                .padding(.horizontal, 28)

            Text("And when it’s posted, and when it takes off. Nothing else.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 36)

            Spacer(minLength: 0)

            OnboardingButton(title: "Turn on pings") {
                Task {
                    await session.askForPushOnce()
                    session.onboardingNext(from: .pings)
                }
            }

            Button("Not now") { session.onboardingNext(from: .pings) }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .softGlassBackground()
        .task { await arrive() }
    }

    /// A phone's lock screen: the date, the time, and pings arriving one by one.
    private var lockScreen: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.08, blue: 0.36), Color(red: 0.36, green: 0.30, blue: 0.9), Color(red: 0.78, green: 0.55, blue: 0.85)],
                startPoint: .top, endPoint: .bottom
            )
            VStack(spacing: 0) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 26)
                Text("9:41")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(.white)

                ZStack(alignment: .top) {
                    ForEach(0..<messages.count, id: \.self) { index in
                        let depth = shown - 1 - index
                        if depth >= 0 {
                            PingBanner(title: "Postpilot", line: messages[index])
                                .scaleEffect(1 - 0.05 * Double(min(depth, 2)))
                                .offset(y: CGFloat(min(depth, 2)) * 10)
                                .opacity(depth == 0 ? 1 : (depth == 1 ? 0.6 : 0.3))
                                .zIndex(Double(index))
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
                .frame(height: 110, alignment: .top)
                .padding(.horizontal, 12)
                .padding(.top, 14)

                Spacer(minLength: 0)
            }
        }
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .shadow(color: Theme.accent.opacity(0.25), radius: 22, y: 12)
    }

    private func arrive() async {
        if reduceMotion { shown = messages.count; return }
        try? await Task.sleep(for: .milliseconds(500))
        while !Task.isCancelled {
            for step in 1...messages.count {
                withAnimation(.spring(duration: 0.6, bounce: 0.25)) { shown = step }
                try? await Task.sleep(for: .milliseconds(1700))
            }
            try? await Task.sleep(for: .milliseconds(1200))
            withAnimation(.easeIn(duration: 0.3)) { shown = 0 }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
