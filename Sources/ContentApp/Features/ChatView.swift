import SwiftUI
import UIKit

/// Ask for ideas, get them written for your account.
///
/// The first useful shape of the agent. It reads your brief and the openings it
/// has already used, so it writes for this account rather than in general and
/// does not repeat itself. It cannot publish, approve, or attach media -- it
/// writes words, and everything that reaches TikTok still goes through the
/// approval sheet.
struct ChatView: View {
    @Environment(AppSession.self) private var session

    @State private var prompt = ""
    @State private var ideas: [Idea] = []
    @State private var isThinking = false
    @State private var copied: String?
    @State private var planning = false
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Composer(
                    prompt: $prompt,
                    isThinking: isThinking,
                    focused: $promptFocused,
                    send: { Task { await ask() } },
                    plan: {
                        promptFocused = false
                        planning = true
                    }
                )

                if ideas.isEmpty && !isThinking {
                    Suggestions { suggestion in
                        prompt = suggestion
                        Task { await ask() }
                    }
                }

                ForEach(ideas) { idea in
                    IdeaCard(idea: idea, copied: copied == idea.id) {
                        UIPasteboard.general.string = "\(idea.caption) \(idea.hashtags.joined(separator: " "))"
                        withAnimation { copied = idea.id }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.canvas)
        .navigationTitle("Chat")
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $planning, onDismiss: {
            // Pushed on dismiss rather than from inside the sheet: a push that
            // races the dismissal animation is dropped, and the button then
            // looks broken to whoever pressed it.
            if proposed != nil { showingPlan = true }
        }) {
            NewPlanSheet(brief: prompt) { proposed = $0 }
        }
        .navigationDestination(isPresented: $showingPlan) {
            // Carried through so the plan can say why it came out short. Kept
            // rather than cleared on dismiss, because the notice belongs to
            // this month and not to the tap that opened it.
            PlanView(notice: proposed)
        }
    }

    private func ask() async {
        let asked = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isThinking else { return }

        promptFocused = false
        isThinking = true
        copied = nil
        defer { isThinking = false }

        ideas = await session.ideas(for: asked)
    }
}

// MARK: - Pieces

private struct Composer: View {
    @Binding var prompt: String
    let isThinking: Bool
    @FocusState.Binding var focused: Bool
    let send: () -> Void
    let plan: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("What should it make?")
                    .font(.subheadline.weight(.semibold))

                TextField("Three ideas about what I learned this week", text: $prompt, axis: .vertical)
                    .lineLimit(2...5)
                    .focused($focused)
                    .disabled(isThinking)

                Button(action: send) {
                    HStack {
                        if isThinking {
                            ProgressView().controlSize(.small).tint(Theme.onAccent)
                            Text("Writing…")
                        } else {
                            Image(systemName: "sparkles")
                            Text("Get ideas")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isThinking || prompt.trimmingCharacters(in: .whitespaces).isEmpty)

                // The bigger ask, and deliberately not disabled on an empty
                // prompt: a month can be planned from the account description
                // alone, and requiring a sentence first would hide the feature
                // behind a blank field.
                Button(action: plan) {
                    HStack {
                        Image(systemName: "calendar.badge.plus")
                        Text("Plan a month")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isThinking)
            }
        }
    }
}

/// Something to press when the screen is empty, rather than a blinking cursor
/// and no idea what this thing expects.
private struct Suggestions: View {
    let pick: (String) -> Void

    private let examples = [
        "Three ideas about what I got wrong this week",
        "Five hooks for people who have never heard of us",
        "Something short about the thing I just shipped",
    ]

    var body: some View {
        Card("Try one of these", systemImage: "lightbulb") {
            VStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button { pick(example) } label: {
                        HStack {
                            Text(example)
                                .font(.subheadline)
                                .foregroundStyle(Color.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(Theme.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct IdeaCard: View {
    let idea: Idea
    let copied: Bool
    let copy: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(idea.hook)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(idea.caption)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !idea.hashtags.isEmpty {
                    Text(idea.hashtags.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                // The reason it picked this. Without it the list is just words
                // that appeared, which is the thing this product is meant not
                // to be.
                if !idea.rationale.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "quote.opening")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(idea.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button(action: copy) {
                    Label(copied ? "Copied" : "Copy caption",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
