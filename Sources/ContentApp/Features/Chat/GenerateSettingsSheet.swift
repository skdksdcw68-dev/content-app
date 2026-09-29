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

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showingModels = false
    /// This month's allowance, read once when the sheet opens.
    @State private var standing: [QuotaStanding] = []

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

                    // Only what this model has. The same rule as the bar (29 Sep
                    // 2026): a row the model cannot honour is not drawn, and
                    // where that is worth explaining -- the shape following a
                    // picture, silence -- the row says so instead of vanishing,
                    // because "where did the sound go?" is a fair question.
                    // (The "number of generations" row is gone: it never made
                    // more than one.)
                    if choices.choosesShape {
                        if choices.aspects.count > 1 {
                            Picker("Aspect Ratio", selection: $choices.aspect) {
                                ForEach(choices.aspects, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } else {
                        LabeledContent("Aspect Ratio", value: "Follows your picture")
                    }

                    if choices.resolutions.count > 1 {
                        Picker("Resolution", selection: $choices.resolution) {
                            ForEach(choices.resolutions, id: \.self) {
                                Text(GenerateChoices.pixelsLabel($0)).tag($0)
                            }
                        }
                    }

                    if choices.isVideo, choices.lengths.count > 1 {
                        Picker("Duration Secs", selection: $choices.seconds) {
                            ForEach(choices.lengths, id: \.self) { Text("\($0)").tag($0) }
                        }
                    }

                    if choices.hasSound {
                        Toggle("Generate Audio", isOn: $choices.audio)
                    } else if choices.isVideo {
                        LabeledContent("Audio", value: choices.makesSound ? "Sound included" : "Silent video")
                    }
                }

                // What the voice says. Only where the model makes sound and it
                // is on -- Veo reads the line out; Kling and Wan cannot.
                //
                // 🔴 Replaces the "Voiceover" and "Captions" switches, which
                // were never sent anywhere. A switch that changes nothing is a
                // lie the size of a switch.
                if choices.canSpeak {
                    Section {
                        TextField("What should the voice say?", text: $choices.voiceover, axis: .vertical)
                            .lineLimit(2...6)
                    } header: {
                        Text("Voiceover")
                    } footer: {
                        Text("Spoken in the video's own sound, in the voice the model chooses.")
                    }
                }

                if choices.takesNegative {
                    Section {
                        TextField("Enter negative prompt", text: $choices.negative, axis: .vertical)
                            .lineLimit(3...6)
                    } header: {
                        Text("Negative Prompt")
                    } footer: {
                        Text("What it should keep out of the shot.")
                    }
                }

                // How far this month goes. Abel, 26 Sep 2026: "the credits
                // how far they can go" -- the same counters the server
                // refuses from, read without spending.
                //
                // 29 Sep 2026: in CREDITS now. Videos and images stopped being
                // counted the day generation started being paid for by what it
                // costs (0077), and a "Videos 60 of 60 left" that never moved
                // would have been a lie.
                if let credits = standing.first(where: { $0.kind == "credit" }) {
                    Section {
                        HStack {
                            Text("Credits")
                            Spacer()
                            Text("\(CreditFormat.text(credits.left)) of \(CreditFormat.text(credits.limitValue)) left")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } header: {
                        Text("This month")
                    } footer: {
                        Text("Credits pay for what you make. The number beside the send button is what this one costs.")
                    }
                } else if !standing.isEmpty {
                    Section {
                        ForEach(standing, id: \.kind) { row in
                            HStack {
                                Text(row.kind == "video_gen" ? "Videos" : "Images")
                                Spacer()
                                Text(row.limitValue == 0 ? "With Pro" : "\(row.left) of \(row.limitValue) left")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    } header: {
                        Text("This month")
                    }
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
                    withPicture: choices.pictured,
                    selected: choices.model?.externalId
                ) { choices.model = $0 }
            }
        }
        .presentationDetents([.large])
        .task { standing = await session.quotaStanding() }
    }
}
