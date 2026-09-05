import SwiftUI

/// First run, in three steps.
///
/// The middle step is the reason this exists. An autopilot with no brief writes
/// generically, and asking for the brand once at the start gets a far better
/// answer than a half-filled form nobody ever opens in Profile. The other two
/// steps are short on purpose: say what it does, then connect.
struct OnboardingView: View {
    /// Set once the intro has been read, so reconnecting later drops straight
    /// to the last step instead of replaying the pitch.
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false

    @Environment(ContentStore.self) private var store
    @State private var step: Step = .welcome

    enum Step: Int, CaseIterable {
        case welcome
        case brief
        case connect
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    switch step {
                    case .welcome: WelcomeStep()
                    case .brief:   BriefStep()
                    case .connect: ConnectStep()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)

            footer
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            // A disconnect should not mean sitting through the pitch again.
            if hasSeenIntro, store.connectionState != .connected {
                step = .connect
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 12) {
            StepDots(current: step)

            if step == .connect {
                ConnectButton()
            } else {
                Button {
                    advance()
                } label: {
                    Text(step == .brief ? "Continue" : "Get started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            if step == .brief {
                Button("Set this up later") { advance() }
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func advance() {
        hasSeenIntro = true
        withAnimation(.snappy) {
            step = Step(rawValue: step.rawValue + 1) ?? .connect
        }
    }
}

// MARK: - Progress

private struct StepDots: View {
    let current: OnboardingView.Step

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingView.Step.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step == current ? Theme.accent : Color(.tertiaryLabel))
                    .frame(width: step == current ? 20 : 6, height: 6)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(OnboardingView.Step.allCases.count)")
    }
}

// MARK: - Step one

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)

                Text("Autocast plans your posts")
                    .font(.largeTitle.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Text("It decides what to make, writes it, and books the slot. You read what it chose and why.")
                    .font(.body)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 20) {
                PitchRow(
                    symbolName: "lightbulb",
                    title: "It picks the idea",
                    detail: "From the subjects you set, spread across them so one does not take over."
                )
                PitchRow(
                    symbolName: "text.alignleft",
                    title: "It writes the whole thing",
                    detail: "Hook, script and caption, in your voice and to a goal you choose."
                )
                PitchRow(
                    symbolName: "paperplane",
                    title: "It can post without asking",
                    detail: "Only once you turn that on. Until then everything waits for you."
                )
            }
        }
    }
}

private struct PitchRow: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.softAccent, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step two

private struct BriefStep: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who is this for?")
                    .font(.largeTitle.weight(.semibold))

                Text("The planner writes from this. Two sentences here is the difference between posts that sound like you and posts that sound like anyone.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 16) {
                BriefField(
                    label: "Name",
                    prompt: "What the account is called",
                    text: $store.brand.name,
                    isMultiline: false
                )
                BriefField(
                    label: "Subject",
                    prompt: "The thing every post comes back to",
                    text: $store.brand.niche,
                    isMultiline: true
                )
                BriefField(
                    label: "Audience",
                    prompt: "Who it is for, as a sentence",
                    text: $store.brand.audience,
                    isMultiline: true
                )
            }
        }
    }
}

private struct BriefField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    let isMultiline: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)

            TextField(prompt, text: $text, axis: isMultiline ? .vertical : .horizontal)
                .lineLimit(isMultiline ? 2...4 : 1...1)
                .padding(14)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }
}

// MARK: - Step three

private struct ConnectStep: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect an account")
                    .font(.largeTitle.weight(.semibold))

                Text("Autocast will not plan for a platform it cannot post to, so this is the last thing it needs.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Asked here rather than buried in Profile, because it is the one
            // setting that changes what the app is allowed to do on its own.
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Ask before posting", isOn: $store.settings.requiresApproval)
                    .padding(14)
                    .background(
                        Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                Text(store.settings.requiresApproval
                     ? "Everything waits in Plan until you approve it. You can change this later in Profile."
                     : "Autocast publishes on its own, without showing you first.")
                    .font(.footnote)
                    .foregroundStyle(store.settings.requiresApproval ? Color.secondary : Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The button that actually links the account. Shared shape with the rest of
/// the flow so the last step does not look like a different screen.
private struct ConnectButton: View {
    @Environment(ContentStore.self) private var store

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task { await store.connect(to: .tiktok) }
            } label: {
                HStack {
                    if store.connectionState == .connecting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: Platform.tiktok.symbolName)
                    }
                    Text(store.connectionState == .connecting ? "Connecting\u{2026}" : "Connect TikTok")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.connectionState == .connecting)

            Text("Nothing is published until you turn autopilot on.")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }
}

#Preview("First run") {
    OnboardingView()
        .environment(ContentStore())
}
