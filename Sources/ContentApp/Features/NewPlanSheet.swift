import SwiftUI
import UniformTypeIdentifiers

/// Three decisions before a month gets written: what it is about, how long, and
/// how often.
///
/// Deliberately three and not ten. Quiet hours, themes and the timezone already
/// exist as settings, and asking again here would be asking a person to
/// re-specify their account every time they want a plan.
struct NewPlanSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    /// Prefilled from whatever was typed in Chat, so pressing "Plan a month"
    /// after writing a sentence does not throw the sentence away.
    @State private var brief: String

    @State private var days = 30
    @State private var postsPerDay = 1
    @State private var showingPaywall = false

    /// The longest plan this person's plan writes (the server enforces it too).
    private var maxDays: Int { session.subscription?.limits.planDays ?? 30 }

    @State private var showingFilePicker = false
    @State private var pasted = ""
    @State private var importing = false
    @State private var showingImportError = false
    @State private var importError = ""

    /// Called with the proposal once it exists, so the caller can push the
    /// preview. The sheet does not navigate; it reports.
    let onProposed: (PlanProposal) -> Void

    /// Written out rather than left to the memberwise initialiser, which is
    /// private the moment a stored property is -- and every @State here is.
    init(brief: String, onProposed: @escaping (PlanProposal) -> Void) {
        _brief = State(initialValue: brief)
        self.onProposed = onProposed
    }

    /// Everything the planner may treat as true: the brand description, the
    /// brief typed here, and each remembered fact.
    private var knownFacts: Int {
        var count = session.facts.count
        if session.brand?.niche.isEmpty == false { count += 1 }
        if session.brand?.audience.isEmpty == false { count += 1 }
        if !brief.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        return count
    }

    var body: some View {
        NavigationStack {
            Form {
                // A plan already written somewhere else comes in as it is.
                Section {
                    Button {
                        showingFilePicker = true
                    } label: {
                        Label("Import a file", systemImage: "doc.badge.plus")
                    }
                    NavigationLink {
                        PastePlanView(text: $pasted) {
                            Task { await importPlan(text: pasted) }
                        }
                    } label: {
                        Label("Paste a plan", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Already have a plan?")
                } footer: {
                    Text("DOCX, PDF, ZIP or text — or paste one from ChatGPT. Your posts are kept as written and laid onto days for you to check.")
                }
                .disabled(session.isPlanning)

                Section {
                    TextField(
                        "What this month is about",
                        text: $brief,
                        axis: .vertical
                    )
                    .lineLimit(3...6)
                    .disabled(session.isPlanning)
                } header: {
                    Text("Or let Autocast write one")
                } footer: {
                    Text("Optional. Your account description and themes are used either way — this is for anything specific to these weeks, like a launch.")
                }

                Section {
                    Picker("How long", selection: $days) {
                        Text("A week").tag(7)
                        Text("Two weeks").tag(14)
                        Text("A month").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .disabled(session.isPlanning)

                    Stepper(
                        "\(postsPerDay) post\(postsPerDay == 1 ? "" : "s") a day",
                        value: $postsPerDay,
                        in: 1...3
                    )
                    .disabled(session.isPlanning)
                } footer: {
                    if days > maxDays {
                        Text("Plans longer than \(maxDays) days are part of Autocast Pro.")
                    } else {
                        Text("\(days * postsPerDay) posts, spread across the hours you have not marked quiet. Today's slot is skipped if it has already passed.")
                    }
                }

                if days > maxDays {
                    Section {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label("Get Autocast Pro", systemImage: "sparkles")
                        }
                    }
                }

                // The single biggest lever on whether the month is worth
                // posting, and the one nobody would guess. The planner is
                // forbidden from inventing specifics, so with nothing to draw
                // on it writes "here is what went into it this week" -- true,
                // and worth nothing. With five facts it writes "no badges, no
                // streaks: here is the reason".
                if knownFacts < 4 {
                    Section {
                        NavigationLink {
                            BrandView()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Tell it more about you first")
                                        .font(.subheadline.weight(.medium))
                                    Text(knownFacts == 0
                                         ? "It knows nothing about this account yet, so it can only write in general terms."
                                         : "It has \(knownFacts) things to go on. Four or five makes a visible difference.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } icon: {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }

                if let existing = session.plan, existing.isProposal {
                    Section {
                        Label(
                            "You already have a plan waiting. Making a new one replaces it.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await propose() }
                    } label: {
                        HStack {
                            if session.isPlanning {
                                BreathingDot(size: 8)
                                Text("Writing \(days * postsPerDay) posts…")
                            } else {
                                Image(systemName: "calendar.badge.plus")
                                Text("Write the plan")
                            }
                            Spacer()
                        }
                    }
                    .disabled(session.isPlanning || days > maxDays)
                } footer: {
                    if session.isPlanning {
                        // Twenty-odd seconds with no explanation reads as a
                        // hang. Saying why it is slow is cheaper than making it
                        // fast, and more honest than a fake progress bar.
                        Text("It writes ten at a time so the later ones are not worse than the early ones. This takes a few seconds.")
                    } else {
                        Text("Nothing is scheduled and nothing is posted. You see all of it first.")
                    }
                }
            }
            // The wait, as Remi's building screen: the whole sheet, a ring and
            // one sentence, instead of a small spinner in a form row nobody is
            // looking at.
            .overlay {
                if session.isPlanning {
                    BuildingLoader(
                        title: importing ? "Reading your plan" : "Writing \(days * postsPerDay) posts",
                        detail: importing
                            ? "Finding every post in it and laying them onto days. Nothing is changed or added."
                            : "It writes ten at a time so the last ones are as good as the first. This takes a few seconds."
                    )
                    .background(Color(uiColor: .systemBackground))
                    .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.25), value: session.isPlanning)
            .navigationTitle("Plan a month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(session.isPlanning)
                }
            }
            .interactiveDismissDisabled(session.isPlanning)
            .task {
                await session.refreshFacts()
                // Start on the longest plan this account can write.
                if days > maxDays { days = maxDays }
            }
            // Presented from here: this is already a sheet, and the root's
            // paywall cannot appear on top of it.
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: Self.importTypes
            ) { result in
                if case .success(let url) = result {
                    Task { await importPlan(file: url) }
                }
            }
            .alert("Couldn't import that", isPresented: $showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError)
            }
        }
    }

    static let importTypes: [UTType] = [
        .pdf, .zip, .plainText, .text, .html, .commaSeparatedText, .rtf,
        UTType(filenameExtension: "docx"),
        UTType(filenameExtension: "md"),
    ].compactMap { $0 }

    private func importPlan(file: URL? = nil, text: String? = nil) async {
        importing = true
        defer { importing = false }
        session.lastError = nil
        guard let proposal = await session.importPlan(file: file, text: text) else {
            // Shown here, over the sheet; the app-wide alert sits behind it.
            importError = session.lastError ?? "Something went wrong. Try again."
            session.lastError = nil
            showingImportError = true
            return
        }
        onProposed(proposal)
        dismiss()
    }

    private func propose() async {
        guard let proposal = await session.proposePlan(
            brief: brief.trimmingCharacters(in: .whitespacesAndNewlines),
            days: days,
            postsPerDay: postsPerDay
        ) else { return }

        // Reported before dismissing, so the caller can act on it once the
        // sheet has finished going away. Pushing a screen in the same tick as a
        // dismiss loses the push often enough to look like a dead button.
        onProposed(proposal)
        dismiss()
    }
}

/// Paste a plan from anywhere -- ChatGPT, Notes, an email -- in one box, with
/// the paste button and the import button inside it.
private struct PastePlanView: View {
    @Binding var text: String
    let onImport: () -> Void

    @Environment(AppSession.self) private var session
    @FocusState private var focused: Bool

    private var ready: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 30
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Day 1 — Hook: …\nDay 2 — Hook: …", text: $text, axis: .vertical)
                        .lineLimit(12...30)
                        .focused($focused)

                    HStack(spacing: 8) {
                        PasteButton(payloadType: String.self) { strings in
                            if let first = strings.first { text = first }
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.titleAndIcon)
                        .tint(Color.secondary)

                        if !text.isEmpty {
                            Button("Clear") { text = "" }
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        Button(action: onImport) {
                            Label("Import", systemImage: "arrow.up")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ready ? Theme.onAccent : Color.secondary)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Capsule().fill(ready ? Color.accentColor : Color.raised))
                        }
                        .buttonStyle(PressButtonStyle())
                        .disabled(!ready || session.isPlanning)
                    }
                }
                .padding(14)
                .background(Color.track, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Text("Days, dates, times, hooks, captions and scripts are all picked up. Anything that isn't a post — goals, tips — is left out.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Style.gutter)
        }
        .background(Color.canvas.ignoresSafeArea())
        .overlay {
            if session.isPlanning {
                BuildingLoader(
                    title: "Reading your plan",
                    detail: "Finding every post in it and laying them onto days. Nothing is changed or added."
                )
                .background(Color(uiColor: .systemBackground))
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: session.isPlanning)
        .navigationTitle("Paste a plan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = text.isEmpty }
    }
}
