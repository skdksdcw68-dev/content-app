import SwiftUI

/// The first screen: what Postpilot makes, playing, before anybody is asked
/// anything (Abel, 7 Nov 2026: "the onboarding shouldn't be something they
/// have to choose before they understand the app"). Cal AI's shape, our look.
struct OnboardingVideoWelcome: View {
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            phoneFrame
                .padding(.bottom, 24)

            Text("Viral videos, made and posted for you")
                .font(.system(size: 30, weight: .bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)

            Spacer(minLength: 16)

            OnboardingButton(title: "Get Started") { session.onboardingNext() }

            Button {
                session.goToEmail(.login)
            } label: {
                Text("Already have an account? **Sign In**")
                    .font(.subheadline)
            }
            .tint(.primary)
            .padding(.top, 16)
            .padding(.bottom, 8)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    /// A sample clip in a rounded frame. With Reduce Motion on it is a still
    /// card instead of a video.
    private var phoneFrame: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return ZStack {
            // Colour behind the video, so there is never an empty white frame
            // while it loads (Abel, 8 Nov 2026).
            LinearGradient(colors: FormatLook.of("didyouknow").colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if reduceMotion {
                FormatCardFace(id: "didyouknow", label: "Did you know?", height: 360)
            } else if let url = ContentTemplate.builtInPreview(for: "facts") {
                SampleLoopVideo(url: url)
            }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .frame(maxHeight: 360)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary, lineWidth: 5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
        .layoutPriority(-1)
        .accessibilityLabel("A video made with Postpilot")
    }
}

// MARK: - How it works

/// What the three pages say. Data, so the flow counts them instead of
/// hard-coding "three".
enum OnboardingTour {
    struct Page {
        let title: String
        let line: String
    }

    static let pages: [Page] = [
        Page(title: "Pick a format once", line: "Same style every time, with a new idea and new scenes in each video."),
        Page(title: "It makes every video", line: "Script, voice, scenes, captions and music. Done in minutes."),
        Page(title: "You approve, it posts", line: "Nothing goes out until you say yes. It posts at the best time."),
    ]
}

/// One "how it works" page: a title at the top, one picture, dots, Continue.
struct OnboardingTourView: View {
    let page: Int

    @Environment(AppSession.self) private var session

    var body: some View {
        let content = OnboardingTour.pages[min(page, OnboardingTour.pages.count - 1)]
        VStack(alignment: .leading, spacing: 0) {
            Text(content.title)
                .font(.system(size: 30, weight: .bold))
                .padding(.horizontal, 20)

            Text(content.line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 6)

            Group {
                switch page {
                case 0: FormatsArt()
                case 1: MakingArt()
                default: ApproveArt()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(page)

            HStack(spacing: 6) {
                ForEach(0..<OnboardingTour.pages.count, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.primary : Color.secondary.opacity(0.3))
                        .frame(width: index == page ? 16 : 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 14)
            .animation(.snappy(duration: 0.25), value: page)

            OnboardingButton(title: "Continue") { session.onboardingNext() }
                .padding(.bottom, 12)
        }
        // Soft glass: a faint purple haze top right, grey bottom left.
        .background {
            ZStack {
                RadialGradient(colors: [Theme.accent.opacity(0.16), .clear], center: UnitPoint(x: 0.9, y: 0.15), startRadius: 0, endRadius: 320)
                RadialGradient(colors: [Color.secondary.opacity(0.18), .clear], center: UnitPoint(x: 0.05, y: 0.9), startRadius: 0, endRadius: 320)
            }
            .ignoresSafeArea()
        }
    }
}

/// Three format cards fanned out.
private struct FormatsArt: View {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            FormatCardFace(id: "motivation", label: "Motivation", height: 190)
                .frame(width: 120)
                .rotationEffect(.degrees(shown ? -9 : 0))
                .offset(x: shown ? -78 : 0, y: shown ? 14 : 0)
            FormatCardFace(id: "scary", label: "Scary story", height: 190)
                .frame(width: 120)
                .rotationEffect(.degrees(shown ? 9 : 0))
                .offset(x: shown ? 78 : 0, y: shown ? 14 : 0)
            FormatCardFace(id: "didyouknow", label: "Did you know?", height: 200)
                .frame(width: 128)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 8)
        }
        .onAppear {
            if reduceMotion { shown = true } else {
                withAnimation(.spring(duration: 0.7, bounce: 0.25)) { shown = true }
            }
        }
    }
}

/// Script, voice and edit, ticking one after another.
private struct MakingArt: View {
    @State private var done = 0
    private let rows: [(String, String, String)] = [
        ("Writes the script", "text.alignleft", "doc.text"),
        ("Records the voice", "waveform", "mic"),
        ("Edits the video", "film", "scissors"),
    ]

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Image(systemName: row.1)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text(row.0).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: index < done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(index < done ? Theme.accent : Color.secondary.opacity(0.4))
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(index <= done ? 1 : 0.5)
            }
        }
        .padding(.horizontal, 20)
        .task {
            for step in 1...rows.count {
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation(.snappy(duration: 0.3)) { done = step }
            }
        }
    }
}

/// Approve is tapped, the networks tick, and it says when it posts.
private struct ApproveArt: View {
    @State private var approved = false
    @State private var ticked = 0

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: FormatLook.of("motivation").colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 40, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your video is ready").font(.subheadline.weight(.semibold))
                    Text("Motivation · 20 s").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(approved ? "Approved" : "Approve")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(approved ? Theme.accent : Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(approved ? Theme.accent.opacity(0.12) : Theme.accent, in: Capsule())

            HStack {
                ForEach(Array(["TikTok", "Reels", "Shorts"].enumerated()), id: \.offset) { index, name in
                    VStack(spacing: 4) {
                        Image(systemName: index < ticked ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(index < ticked ? Theme.accent : Color.secondary.opacity(0.4))
                            .contentTransition(.symbolEffect(.replace))
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text("Posts today at 6:30 PM")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .opacity(ticked == 3 ? 1 : 0)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.snappy(duration: 0.25)) { approved = true }
            for step in 1...3 {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.snappy(duration: 0.25)) { ticked = step }
            }
        }
    }
}
