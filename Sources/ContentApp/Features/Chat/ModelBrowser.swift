import SwiftUI

/// Every model, grouped the way people talk about them.
///
/// The Generate card shows eight rows. This is the rest of them, and it exists
/// because eight was hiding the good ones: "on nano banana there is two, on
/// kling there is also... right now its not showing the best". Families come
/// from what the models are called, so a provider connected tomorrow groups
/// itself.
///
/// Prices arrive as rows come into view, a dozen at a time. A price is a
/// provider request, and asking for forty to draw a list would spend forty of
/// them on a scroll.
struct ModelBrowser: View {
    let capability: String
    /// What is being made, so each price is this job's price.
    let request: String
    let settings: GenerationSettings
    let withPicture: Bool
    let selected: String?
    let onPick: (ModelChoice) -> Void

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var models: [ModelChoice] = []
    @State private var costs: [String: ModelCost] = [:]
    /// Seen on screen and not yet priced, and everything already asked about.
    @State private var waiting: Set<String> = []
    @State private var asked: Set<String> = []
    @State private var pricing: Task<Void, Never>?
    @State private var search = ""
    @State private var loading = true

    private var isVideo: Bool { capability == "video_generation" }

    private var matching: [ModelChoice] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return models }
        return models.filter {
            $0.label.lowercased().contains(words)
                || ($0.family?.lowercased().contains(words) ?? false)
                || ($0.about?.lowercased().contains(words) ?? false)
                || $0.externalId.lowercased().contains(words)
        }
    }

    /// Families in the order the server sent them -- what it would pick first,
    /// then the provider's own ranking.
    private var families: [(name: String, models: [ModelChoice])] {
        var order: [String] = []
        var grouped: [String: [ModelChoice]] = [:]
        for model in matching {
            let name = model.family ?? model.label
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(model)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(families, id: \.name) { family in
                    Section {
                        ForEach(family.models) { model in
                            Button { pick(model) } label: {
                                ModelBrowserRow(
                                    model: model,
                                    price: costs[model.externalId] ?? model.cost,
                                    isSelected: model.externalId == selected,
                                    isVideo: isVideo
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(model.suitable == false)
                            .onAppear { want(model.externalId) }
                        }
                    } header: {
                        HStack {
                            Text(family.name)
                            if family.models.count > 1 {
                                Text("\(family.models.count)")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "Search models")
            .navigationTitle(isVideo ? "Video models" : "Image models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if loading {
                    ProgressView()
                } else if models.isEmpty {
                    ContentUnavailableView(
                        "Nothing connected yet",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Connect a generator from the plus menu.")
                    )
                } else if matching.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
        .task {
            models = await session.models(capability: capability, withPicture: withPicture)
            loading = false
        }
        .onDisappear { pricing?.cancel() }
    }

    private func pick(_ model: ModelChoice) {
        var picked = model
        // Carry the price this browser already showed, so the card does not
        // open on "Cost not stated" for something it just quoted.
        if let quoted = costs[model.externalId] {
            picked = ModelChoice(
                modelId: model.modelId,
                provider: model.provider,
                label: model.label,
                externalId: model.externalId,
                cost: quoted,
                constraints: model.constraints,
                reason: model.reason,
                recommended: model.recommended,
                affordable: model.affordable,
                badges: model.badges,
                family: model.family,
                about: model.about,
                suitable: model.suitable
            )
        }
        onPick(picked)
        dismiss()
    }

    /// Row seen; price it with the next batch.
    private func want(_ id: String) {
        guard !asked.contains(id), costs[id] == nil else { return }
        waiting.insert(id)
        guard pricing == nil else { return }
        pricing = Task {
            // A moment, so a flick through three families asks once.
            try? await Task.sleep(for: .milliseconds(300))
            while !Task.isCancelled, !waiting.isEmpty {
                let batch = Array(waiting.prefix(12))
                waiting.subtract(batch)
                asked.formUnion(batch)
                let quoted = await session.quote(
                    capability: capability,
                    models: batch,
                    prompt: request,
                    settings: settings
                )
                costs.merge(quoted) { _, new in new }
            }
            pricing = nil
        }
    }
}

/// One model in the browser: what it is called, what it is for, what it costs.
private struct ModelBrowserRow: View {
    let model: ModelChoice
    let price: ModelCost
    let isSelected: Bool
    let isVideo: Bool

    private var usable: Bool { model.suitable != false && model.affordable != false }

    private var detail: String? {
        if model.suitable == false {
            return isVideo ? "Needs a video or picture to work on" : "Needs a picture to work on"
        }
        if model.affordable == false { return "More than your balance" }
        return model.about ?? model.constraints.notes?.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Theme.accent : Color.secondary.opacity(0.4))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    ForEach(model.badges ?? [], id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(badge == "Cheapest" ? Color.green : Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((badge == "Cheapest" ? Color.green : Theme.accent).opacity(0.12)))
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(model.suitable == false ? Color.secondary : Color.secondary)
                        .lineLimit(2)
                }
                if let resolutions = model.constraints.resolutions, resolutions.count > 1 {
                    Text(resolutions.map { $0.hasSuffix("k") ? $0.uppercased() : $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            Text(price.amount == nil ? "—" : price.label)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(price.amount == nil ? Color.secondary : Color.primary)
        }
        .padding(.vertical, 4)
        .opacity(usable ? 1 : 0.5)
        .contentShape(Rectangle())
    }
}
