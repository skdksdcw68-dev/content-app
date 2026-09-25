import SwiftUI

/// Everything the bar does not show, laid out the way ElevenLabs lays it out.
///
/// X on the left, the word "Settings", a filled tick on the right. A segmented
/// Image | Video under it, and then a plain list of label-on-the-left,
/// value-on-the-right rows.
///
/// The thing worth copying is what ElevenLabs does NOT do: the video tab has
/// seven rows and the image tab has three, and they do not pad the image tab
/// out to match. A setting that does not apply to images is simply not there.
struct GenerateSettingsSheet: View {
    @Binding var choices: GenerateChoices
    let request: String

    @Environment(\.dismiss) private var dismiss
    @State private var showingModels = false

    private static let lengths = Array(stride(from: 5, through: 180, by: 5))
    private static let aspects = ["9:16", "1:1", "4:5", "16:9"]
    private static let resolutions = ["480p", "720p", "1080p"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("", selection: $choices.mode) {
                        ForEach(GenerateChoices.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                Section {
                    // Model. A row that opens the picker, rather than a wheel
                    // with forty entries on it.
                    Button { showingModels = true } label: {
                        HStack {
                            Text("Model").foregroundStyle(.primary)
                            Spacer(minLength: 8)
                            Text(choices.model?.label ?? "Best available")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Picker("Number of generations", selection: Binding(
                        get: { choices.count }, set: { choices.count = $0 }
                    )) {
                        ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                    }

                    Picker("Aspect Ratio", selection: $choices.aspect) {
                        ForEach(Self.aspects, id: \.self) { Text($0).tag($0) }
                    }

                    if choices.isVideo {
                        Picker("Resolution", selection: $choices.resolution) {
                            ForEach(Self.resolutions, id: \.self) { Text($0).tag($0) }
                        }

                        Picker("Duration Secs", selection: $choices.seconds) {
                            ForEach(Self.lengths, id: \.self) { Text("\($0)").tag($0) }
                        }

                        Toggle("Generate Audio", isOn: $choices.audio)
                    }
                }

                if choices.isVideo {
                    // Autocast's own two. ElevenLabs has no equivalent, and
                    // they are what makes a short-form video rather than a
                    // clip, so they get their own group rather than being
                    // smuggled in above.
                    Section {
                        Toggle("Voiceover", isOn: $choices.voiceover)
                        Toggle("Captions", isOn: $choices.captions)
                    } header: {
                        Text("On the video")
                    }
                }

                Section {
                    TextField("Enter negative prompt", text: $choices.negative, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Negative Prompt")
                } footer: {
                    Text("What it should keep out of the shot.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark")
                    }
                    .accessibilityLabel("Done")
                }
            }
            .sheet(isPresented: $showingModels) {
                ModelBrowser(
                    capability: choices.mode.capability,
                    request: request,
                    settings: choices.settings,
                    withPicture: false,
                    selected: choices.model?.externalId
                ) { choices.model = $0 }
            }
        }
        .presentationDetents([.large])
    }
}
