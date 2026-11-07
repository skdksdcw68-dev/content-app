import SwiftUI

/// Who answers in the chat, picked from the chip in the chat bar the way
/// Claude does it (Abel, 5 Nov 2026, of the mockup: "this is... insane").
///
/// Auto is the default and the right answer for most people: Haiku answers
/// talk at once, Sonnet thinks when the question needs it. Picking a model
/// changes only who writes the reply; looking things up on the web always goes
/// to OpenAI, and pictures and videos keep their own picker. Kept on the phone.
struct ChatModelPrefs: Equatable {
    /// "auto", "sonnet", "haiku", "opus", "terra" or "luna" -- what the server reads.
    var model: String
    /// "low", "medium" or "high": how long a thinking model thinks.
    var effort: String

    private static let modelKey = "chat.model"
    private static let effortKey = "chat.effort"

    static var current: ChatModelPrefs {
        get {
            let defaults = UserDefaults.standard
            return ChatModelPrefs(
                model: defaults.string(forKey: modelKey) ?? "auto",
                effort: defaults.string(forKey: effortKey) ?? "medium"
            )
        }
        set {
            UserDefaults.standard.set(newValue.model, forKey: modelKey)
            UserDefaults.standard.set(newValue.effort, forKey: effortKey)
        }
    }

    /// The name on the chip.
    var chipTitle: String {
        switch model {
        case "sonnet": "Sonnet 5.5"
        case "haiku": "Haiku 5.5"
        case "opus": "Opus 5.5"
        case "terra": "Terra"
        case "luna": "Luna"
        default: "Auto"
        }
    }

    /// Models whose thinking time can be chosen. Auto decides for itself, and
    /// Haiku and Luna always answer straight away (Abel, 7 Nov 2026: "let it
    /// depend on the model").
    var thinks: Bool {
        ["sonnet", "opus", "terra"].contains(model)
    }

    /// The effort beside the name, for the models that think.
    var chipEffort: String? {
        thinks ? Self.effortName(effort) : nil
    }

    /// What the server is sent: the chosen effort for a thinking model, the
    /// default otherwise, so Auto is not steered by a choice made for Sonnet.
    var sentEffort: String {
        thinks ? effort : "medium"
    }

    /// What the person sees for the three levels the server knows.
    static func effortName(_ effort: String) -> String {
        switch effort {
        case "low": "Fast"
        case "high": "Deep"
        default: "Normal"
        }
    }
}

/// The chip in the chat bar: the model and its effort, and a small chevron.
struct ModelChip: View {
    let prefs: ChatModelPrefs
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Text(prefs.chipTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                // Claude's chip: "Sonnet 4.6 Low".
                if let effort = prefs.chipEffort {
                    Text(effort)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressButtonStyle())
        .accessibilityLabel("Model: \(prefs.chipTitle)")
    }
}

/// Claude's "Select model" sheet: the three that matter, then Effort and More
/// models, each a page of its own inside the sheet.
struct ModelPickerSheet: View {
    @Binding var prefs: ChatModelPrefs
    /// 0 free, 1 Pro, 2 Max, 3 Ultra: Opus is Max and Ultra.
    let planRank: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ModelRow(title: "Auto", detail: "Haiku for talk, Sonnet when it needs to think", tag: "Best",
                             isChosen: prefs.model == "auto") { choose("auto") }
                    ModelRow(title: "Sonnet 5.5", detail: "Best for ideas, scripts and prompts",
                             isChosen: prefs.model == "sonnet") { choose("sonnet") }
                    ModelRow(title: "Haiku 5.5", detail: "Fastest for quick answers",
                             isChosen: prefs.model == "haiku") { choose("haiku") }
                }
                .listRowBackground(GrokLook.card(scheme))

                if prefs.thinks {
                    Section {
                        NavigationLink {
                            EffortPage(prefs: $prefs)
                        } label: {
                            LabeledContent("Effort", value: ChatModelPrefs.effortName(prefs.effort))
                        }
                    }
                    .listRowBackground(GrokLook.card(scheme))
                }

                Section {
                    NavigationLink {
                        MoreModelsPage(prefs: $prefs, planRank: planRank, choose: choose)
                    } label: {
                        LabeledContent("More models", value: ["opus", "terra", "luna"].contains(prefs.model) ? prefs.chipTitle : "")
                    }
                } footer: {
                    Text("Web answers always look things up with OpenAI. Pictures and videos keep their own picker.")
                }
                .listRowBackground(GrokLook.card(scheme))
            }
            .scrollContentBackground(.hidden)
            .background(GrokLook.sheet(scheme).ignoresSafeArea())
            .navigationTitle("Select model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .grokSettings()
        // A short sheet whose list scrolls; never full screen (Abel, 7 Nov 2026).
        .presentationDetents([.medium])
        .presentationCornerRadius(34)
    }

    /// Picks it, and closes a moment later so the tick is seen landing.
    private func choose(_ model: String) {
        withAnimation(.snappy(duration: 0.18)) { prefs.model = model }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            dismiss()
        }
    }
}

/// One model: its name, an optional tag, a line under it, and a tick.
private struct ModelRow: View {
    let title: String
    let detail: String
    var tag: String?
    var tagIsPlan = true
    let isChosen: Bool
    var isLocked = false
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(isLocked ? .secondary : .primary)
                        if let tag {
                            Text(tag)
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .foregroundStyle(tagIsPlan ? Color.accentColor : Color.secondary)
                                .background(Capsule().fill((tagIsPlan ? Color.accentColor : Color.secondary).opacity(0.16)))
                        }
                    }
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityAddTraits(isChosen ? [.isSelected, .isButton] : .isButton)
    }
}

/// How long Sonnet thinks before it writes.
private struct EffortPage: View {
    @Binding var prefs: ChatModelPrefs
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List {
            Section {
                ModelRow(title: "Fast", detail: "Quickest, thinks a little", isChosen: prefs.effort == "low") { set("low") }
                ModelRow(title: "Normal", detail: "Balanced, the default", isChosen: prefs.effort == "medium") { set("medium") }
                ModelRow(title: "Deep", detail: "Slowest, thinks the most", isChosen: prefs.effort == "high") { set("high") }
            } footer: {
                Text("Effort is how long Sonnet thinks before it writes. More thinking gives better scripts and prompts, and takes a few seconds longer. Haiku always answers straight away.")
            }
            .listRowBackground(GrokLook.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("Effort")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func set(_ effort: String) {
        withAnimation(.snappy(duration: 0.18)) { prefs.effort = effort }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

/// The rest: Opus for Max and Ultra, and OpenAI's two.
private struct MoreModelsPage: View {
    @Binding var prefs: ChatModelPrefs
    let planRank: Int
    let choose: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        List {
            Section {
                ModelRow(title: "Opus 5.5", detail: "For the hardest questions", tag: "Max",
                         isChosen: prefs.model == "opus", isLocked: planRank < 2) { choose("opus") }
                ModelRow(title: "GPT-5.6 Terra", detail: "Strong all-rounder", tag: "OpenAI", tagIsPlan: false,
                         isChosen: prefs.model == "terra") { choose("terra") }
                ModelRow(title: "GPT-5.6 Luna", detail: "Quick and light", tag: "OpenAI", tagIsPlan: false,
                         isChosen: prefs.model == "luna") { choose("luna") }
            } footer: {
                Text(planRank < 2
                     ? "Opus comes with Max and Ultra. Your pick stays until you change it."
                     : "Your pick stays until you change it.")
            }
            .listRowBackground(GrokLook.card(scheme))
        }
        .scrollContentBackground(.hidden)
        .background(GrokLook.sheet(scheme).ignoresSafeArea())
        .navigationTitle("More models")
        .navigationBarTitleDisplayMode(.inline)
    }
}
