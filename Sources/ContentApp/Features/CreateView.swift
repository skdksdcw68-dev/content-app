import SwiftUI
import PhotosUI

/// Everything that starts something, in one place.
///
/// Reached from the detached "+" beside the tab bar. Until now the two ways to
/// begin -- plan a month, add a video -- were buried one in Chat and one behind
/// a toolbar button in Library, which is a strange place to hide the only two
/// things this app is for.
struct CreateView: View {
    @Environment(AppSession.self) private var session

    @State private var planning = false
    @State private var proposed: PlanProposal?
    @State private var showingPlan = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var caption = ""
    @State private var pendingVideo: (data: Data, filename: String)?
    @State private var namingVideo = false
    @State private var pickingVideo = false
    /// What to make, in their words, and whether it has been sent.
    @State private var asked = ""
    @State private var starting = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Say it, and it starts. Create is for beginning one thing --
                // "make three ad concepts", "a product video" -- and the
                // conversation it opens is where the rest of it happens. The
                // two buttons below are the jobs that are not a sentence.
                AskBox(text: $asked) { starting = true }

                CreateAction(
                    symbol: "calendar.badge.plus",
                    title: "Plan a month",
                    detail: "Thirty posts with a time against each one. You see all of it before anything is scheduled.",
                    prominent: true
                ) {
                    planning = true
                }

                CreateAction(
                    symbol: "video.badge.plus",
                    title: "Add a video",
                    detail: "Something you already made. It waits for your approval before it goes anywhere."
                ) {
                    pickingVideo = true
                }

                if session.hasWorkingGenerator {
                    MadeForYouNote()
                } else {
                    ConnectGeneratorNote()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.canvas)
        .navigationTitle("Create")
        .photosPicker(isPresented: $pickingVideo, selection: $pickerItem, matching: .videos)
        .task(id: pickerItem) { await loadPicked() }
        .sheet(isPresented: $planning, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) {
            NewPlanSheet(brief: "") { proposed = $0 }
        }
        .sheet(isPresented: $namingVideo) { captionSheet }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
        .navigationDestination(isPresented: $starting) {
            ChatView(opening: asked.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }


    private var captionSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Say something about it", text: $caption, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Caption")
                } footer: {
                    Text("You will see this again, with the account it is going to, before anything is posted.")
                }
            }
            .navigationTitle("New post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pendingVideo = nil
                        namingVideo = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await upload() } }
                        .disabled(session.isWorking)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func loadPicked() async {
        guard let pickerItem else { return }
        do {
            guard let movie = try await pickerItem.loadTransferable(type: Movie.self) else { return }
            let data = try Data(contentsOf: movie.url)
            try? FileManager.default.removeItem(at: movie.url)
            pendingVideo = (data, movie.url.lastPathComponent)
            caption = ""
            namingVideo = true
        } catch {
            session.lastError = "That video could not be read."
        }
        self.pickerItem = nil
    }

    private func upload() async {
        guard let pendingVideo else { return }
        namingVideo = false
        await session.addVideo(
            data: pendingVideo.data,
            filename: pendingVideo.filename,
            caption: caption
        )
        self.pendingVideo = nil
    }
}

// MARK: - Pieces

/// Say what to make, and it starts.
///
/// Not a form and not a second chat: one line, a few examples worth stealing,
/// and a button that opens the conversation where the work happens. Everything
/// it can actually do comes from what is connected, so nothing here promises a
/// kind of job -- the examples are examples.
private struct AskBox: View {
    @Binding var text: String
    let onStart: () -> Void

    @FocusState private var typing: Bool

    private static let examples = [
        "A product video for this week",
        "Three ad concepts",
        "Five images using my product as a reference",
        "Turn this idea into a campaign",
    ]

    private var ready: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What should I make?")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 10) {
                TextField("A video about…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .focused($typing)
                    .submitLabel(.go)
                    .onSubmit { if ready { onStart() } }

                Button(action: onStart) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(ready ? Theme.onAccent : Color.secondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(ready ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.08))))
                }
                .buttonStyle(PressButtonStyle())
                .disabled(!ready)
                .accessibilityLabel("Start")
            }

            if !ready {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.examples, id: \.self) { example in
                            Button { text = example } label: {
                                Text(example)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(PressButtonStyle())
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollClipDisabled()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.surface)
        }
    }
}

private struct CreateAction: View {
    let symbol: String
    let title: String
    let detail: String
    var prominent = false
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(prominent ? Theme.onAccent : Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.softAccent),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Theme.surface,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Says what happens without being asked, so "plan a month" is not mistaken for
/// "and then I film thirty videos".
private struct MadeForYouNote: View {
    var body: some View {
        Card("It can make them too", systemImage: "wand.and.stars") {
            Text("Every day in a plan has a line saying what the video shows. Press Make it on any of them, or turn on autopilot and it starts each one a day before its slot.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ConnectGeneratorNote: View {
    var body: some View {
        Card("Want it to film them as well?", systemImage: "wand.and.stars") {
            Text("Add your generator key under You → Generators and it can make each video from the plan's own description.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
