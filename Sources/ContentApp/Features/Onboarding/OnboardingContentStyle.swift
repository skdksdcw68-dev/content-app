import SwiftUI
import UIKit

/// The last thing onboarding asks, and the biggest: which of the 37 content
/// styles this account makes.
///
/// Abel, 24 Sep 2026: "make the onboarding of choosing a content". It used to
/// live only inside the series flow, which meant the app could finish setup
/// knowing everything about somebody except the one thing it needs to write
/// them a month. Now the answer is in before the ring, and the series flow
/// opens already on it.
///
/// The same tiles as the series flow -- one field, no shelves, the picture or
/// its cover -- because they are the same 37 things and should not look like
/// two different products.
///
/// Skippable on purpose. Somebody who does not know yet gets a style chosen
/// for them from what they already said they are promoting, and can change it
/// whenever; making this a wall would be asking a stranger to commit before
/// they have seen anything work.
struct OnboardingContentStyle: View {
    @Environment(AppSession.self) private var session

    @State private var templates: [ContentTemplate]?
    @State private var failed = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var chosen: ContentTemplate? { session.onboardingStyle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What kind of videos?")
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Pick the style it makes for you. Each one comes with its own brief, themes and look. You can change it later.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            ScrollView {
                if let templates, !templates.isEmpty {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(templates) { template in
                            StyleTile(template: template, isChosen: chosen?.slug == template.slug) {
                                pick(template)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                } else if failed {
                    // The catalogue lives on the server, and setup must not
                    // dead-end because a request failed. Say so, offer another
                    // go, and let Continue past it.
                    VStack(spacing: 10) {
                        Text("Couldn't load the styles")
                            .font(.subheadline.weight(.semibold))
                        Text("You can pick one later from Home.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.track)
                                .frame(height: 164)
                        }
                    }
                    .padding(.horizontal, 20)
                    .breathing()
                }
            }
            .scrollIndicators(.hidden)

            // Never disabled, like the multi-select questions: nothing picked
            // costs a little quality and nothing else.
            OnboardingButton(
                title: chosen == nil ? "Decide for me" : "Continue",
                tint: chosen == nil ? Color.secondary : Theme.accent
            ) {
                session.onboardingNext(from: .contentStyle)
            }
            .padding(.top, 10)
            .animation(.snappy(duration: 0.2), value: chosen?.slug)
        }
        .task { if templates == nil { await load() } }
    }

    private func load() async {
        failed = false
        let loaded = await session.templates()
        templates = loaded
        failed = loaded.isEmpty
    }

    private func pick(_ template: ContentTemplate) {
        withAnimation(.snappy(duration: 0.18)) {
            // Tapping the chosen one again clears it, the way the single-select
            // questions behave.
            session.onboardingStyle = chosen?.slug == template.slug ? nil : template
        }
        guard session.onboardingStyle != nil else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // The same settle the questions use: long enough to see the pick land,
        // short enough not to feel like waiting.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard session.onboardingStyle?.slug == template.slug else { return }
            session.onboardingNext(from: .contentStyle)
        }
    }
}
