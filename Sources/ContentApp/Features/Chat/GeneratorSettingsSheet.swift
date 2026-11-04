import SwiftUI

/// The generator's settings, set once -- Grok's Imagine Settings, ours.
///
/// Abel, 1 Nov 2026: no card asking for a model and a quality on every
/// request. The model, how many pictures, their shape and quality, and a
/// video's length and resolution live here, behind the sliders in the chat
/// bar, and everything made starts on them. Saved the moment they change.
struct GeneratorSettingsSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = GeneratorPrefs.current
    @State private var imageModels: [ModelChoice] = []
    @State private var videoModels: [ModelChoice] = []
    @State private var picking: Kind?

    enum Kind: String, Identifiable, Hashable {
        case image, video
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    heading("Pictures")
                    modelRow(.image)
                    if prefs.imageModel != nil {
                        // The chat's "Don't ask me again", undone here.
                        row("Ask before making") {
                            Toggle("Ask before making", isOn: Binding(
                                get: { prefs.imageSkipsSheet != true },
                                set: { prefs.imageSkipsSheet = $0 ? nil : true }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                    row("Pictures each time") {
                        segments(GeneratorPrefs.counts, selection: $prefs.imageCount) { "\($0)" }
                    }
                    shapeRow
                    row("Quality") {
                        segments(GeneratorPrefs.qualities, selection: $prefs.imageQuality) { $0 }
                    }

                    heading("Videos")
                        .padding(.top, 14)
                    modelRow(.video)
                    if prefs.videoModel != nil {
                        row("Ask before making") {
                            Toggle("Ask before making", isOn: Binding(
                                get: { prefs.videoSkipsSheet != true },
                                set: { prefs.videoSkipsSheet = $0 ? nil : true }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                    row("Length") {
                        segments(GeneratorPrefs.lengths, selection: $prefs.videoSeconds) { "\($0)s" }
                    }
                    row("Resolution") {
                        segments(GeneratorPrefs.resolutions, selection: $prefs.videoResolution) { $0 }
                    }

                    Text("Used for everything you make until you change it. What you say wins: “2 of these, square” makes 2 square ones.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.top, 8)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Create settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(item: $picking) { kind in
                ModelPickList(
                    title: kind == .image ? "Picture model" : "Video model",
                    models: kind == .image ? imageModels : videoModels,
                    selected: kind == .image ? $prefs.imageModel : $prefs.videoModel,
                    selectedLabel: kind == .image ? $prefs.imageModelLabel : $prefs.videoModelLabel
                )
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: prefs) { _, changed in GeneratorPrefs.current = changed }
        .task {
            imageModels = await session.models(capability: "image_generation", withPicture: false)
            videoModels = await session.models(capability: "video_generation", withPicture: false)
        }
    }

    // MARK: - Pieces

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
    }

    private func modelRow(_ kind: Kind) -> some View {
        let chosen = kind == .image ? prefs.imageModelLabel : prefs.videoModelLabel
        return Button { picking = kind } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chosen ?? "Auto")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(chosen == nil ? "Model · the best for the price, picked for you" : "Model")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 62)
            .background(card)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .background(card)
    }

    /// Grok's segmented pills: the chosen one filled, the rest quiet.
    private func segments<T: Hashable>(_ options: [T], selection: Binding<T>, label: @escaping (T) -> String) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = selection.wrappedValue == option
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection.wrappedValue = option }
                } label: {
                    Text(label(option))
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Color(.systemBackground) : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background {
                            if on { Capsule().fill(Color.primary) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .sensoryFeedback(.selection, trigger: selection.wrappedValue)
    }

    private var shapeRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shape")
                .font(.body)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(GeneratorPrefs.imageShapes, id: \.self) { shape in
                    let on = prefs.imageAspect == shape
                    let size = tile(shape)
                    Button {
                        withAnimation(.snappy(duration: 0.18)) { prefs.imageAspect = shape }
                    } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(on ? Color.primary : Color.primary.opacity(0.14))
                                .frame(width: size.width, height: size.height)
                            Text(shape)
                                .font(.caption.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Shape \(shape)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .sensoryFeedback(.selection, trigger: prefs.imageAspect)
        }
        .padding(14)
        .background(card)
    }

    /// The tile for a shape, fitted in a 38-point box.
    private func tile(_ shape: String) -> CGSize {
        let parts = shape.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return CGSize(width: 30, height: 30) }
        let ratio = parts[0] / parts[1]
        let box = 38.0
        return ratio >= 1 ? CGSize(width: box, height: box / ratio) : CGSize(width: box * ratio, height: box)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}

/// Which model the generator uses: Auto, or one of the person's own, each with
/// its share of the month per picture or clip.
private struct ModelPickList: View {
    let title: String
    let models: [ModelChoice]
    @Binding var selected: String?
    @Binding var selectedLabel: String?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                pick(id: nil, name: "Auto", detail: "The best for the price, picked for each request", price: nil)
            }
            Section {
                if models.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
                ForEach(models) { model in
                    pick(id: model.externalId, name: model.label, detail: model.about ?? model.reason, price: model.cost)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(id: String?, name: String, detail: String?, price: ModelCost?) -> some View {
        Button {
            selected = id
            selectedLabel = id == nil ? nil : name
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if let share = session.usageShare(of: price) {
                    Text(UsageFormat.short(share))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if selected == id {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
