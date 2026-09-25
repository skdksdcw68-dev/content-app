import SwiftUI

/// Every model, the way ElevenLabs lists them.
///
/// Abel sent fifteen screenshots on 25 Sep 2026 and this is the one that
/// mattered most: "lets go match the video and image generator thing to
/// exactly that."
///
/// What their list gets right, and what the old grouped `List` here got wrong:
///
///   - The MAKER'S TILE comes first, before any words. With forty-one video
///     models the eye finds the row by colour and then reads it. Sections
///     named after families did the opposite -- you had to read every header
///     to find anything.
///   - ONE LINE about what it is for, from the provider, under the name. Not
///     badges, not resolutions, not a reason. A sentence.
///   - THE PRICE is right-aligned on its own, so the column scans as a column.
///   - THE CHOSEN ONE wears a hairline border around the whole row rather than
///     a tick in a gutter, so it reads as "this is the one" instead of "here
///     is a list of radio buttons".
///   - FILTERS ARE PILLS along the top, and SEARCH FLOATS at the bottom, in
///     reach of a thumb, over the list rather than pushing it down.
///
/// Prices still arrive as rows come into view, a dozen at a time. A price is a
/// provider request, and asking for forty-one to draw a list would spend
/// forty-one of them on a scroll.
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
    @State private var filter: Filter = .all
    @State private var loading = true

    private var isVideo: Bool { capability == "video_generation" }

    /// The pills along the top. Each one answers a question somebody actually
    /// arrives with, and each is decided from what the provider already told
    /// us -- nothing here is a list of model names to maintain.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case recommended = "Recommended"
        case cheap = "Cheap"
        case editing = "Editing"
        case fast = "Fast"
        var id: String { rawValue }

        func matches(_ model: ModelChoice, cheapest: Double?) -> Bool {
            let words = "\(model.label) \(model.about ?? "") \(model.externalId)".lowercased()
            switch self {
            case .all:
                return true
            case .recommended:
                return model.recommended || (model.badges?.isEmpty == false)
            case .cheap:
                guard let cheapest, let amount = model.cost.amount else { return false }
                // Within half again of the cheapest thing that can do the job.
                return amount <= cheapest * 1.5
            case .editing:
                return words.contains("edit") || words.contains("upscale")
                    || words.contains("remove") || words.contains("outpaint")
                    || words.contains("replace") || words.contains("reframe")
            case .fast:
                return words.contains("fast") || words.contains("lite")
                    || words.contains("turbo") || words.contains("quick")
                    || words.contains("mini") || words.contains("flash")
            }
        }
    }

    private var cheapest: Double? {
        models.compactMap { costs[$0.externalId]?.amount ?? $0.cost.amount }.min()
    }

    private var shown: [ModelChoice] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        let floor = cheapest
        return models.filter { model in
            guard filter.matches(model, cheapest: floor) else { return false }
            guard !words.isEmpty else { return true }
            return model.label.lowercased().contains(words)
                || (model.family?.lowercased().contains(words) ?? false)
                || (model.about?.lowercased().contains(words) ?? false)
                || ModelMaker.of(model).name.lowercased().contains(words)
                || model.externalId.lowercased().contains(words)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8, pinnedViews: []) {
                        // The capability, once, the way they head the list
                        // "Image" -- not one header per family.
                        Text(isVideo ? "Video" : "Image")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Style.gutter)
                            .padding(.top, 4)

                        ForEach(shown) { model in
                            Button { pick(model) } label: {
                                ModelRow(
                                    model: model,
                                    price: costs[model.externalId] ?? model.cost,
                                    isSelected: model.externalId == selected,
                                    isVideo: isVideo
                                )
                            }
                            .buttonStyle(SoftPressStyle())
                            .disabled(model.suitable == false)
                            .onAppear { want(model.externalId) }
                            .padding(.horizontal, Style.gutter)
                        }

                        // Room for the floating search pill to sit over.
                        Color.clear.frame(height: 76)
                    }
                    .padding(.top, 4)
                }
                .scrollDismissesKeyboard(.interactively)

                searchPill
            }
            .safeAreaInset(edge: .top, spacing: 0) { filters }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
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
                } else if shown.isEmpty {
                    ContentUnavailableView(
                        "Nothing matches",
                        systemImage: "magnifyingglass",
                        description: Text(search.isEmpty ? "Try another filter." : "Try another word.")
                    )
                }
            }
        }
        .task {
            models = await session.models(capability: capability, withPicture: withPicture)
            loading = false
        }
        .onDisappear { pricing?.cancel() }
    }

    // MARK: - Pieces

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    let on = option == filter
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { filter = option }
                    } label: {
                        Text(option.rawValue)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(on ? Theme.onAccent : Color.primary)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(
                                on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.track),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
            .padding(.horizontal, Style.gutter)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    /// In reach of a thumb, over the list rather than above it.
    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .padding(.horizontal, Style.gutter)
        .padding(.bottom, 12)
    }

    // MARK: - Doing

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
            // A moment, so a flick through three screens asks once.
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

// MARK: - One model

/// The maker's tile, the name, one line about it, and the price.
private struct ModelRow: View {
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
        HStack(alignment: .center, spacing: 14) {
            ModelMakerMark(maker: ModelMaker.of(model))

            VStack(alignment: .leading, spacing: 3) {
                Text(model.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(price.amount == nil ? "—" : price.label)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(price.amount == nil ? Color.secondary : Color.primary)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous)
                .fill(Color.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous)
                // The chosen one is outlined, not ticked.
                .strokeBorder(isSelected ? Color.primary : Color.clear, lineWidth: 1.5)
        )
        .opacity(usable ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
