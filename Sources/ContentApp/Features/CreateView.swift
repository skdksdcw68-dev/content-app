import SwiftUI
import TipKit
import PhotosUI

/// Everything that starts something, laid out the way TikTok Studio's Create is.
///
/// Abel sent Studio's Create as a reference and left the call to me (15 Sep
/// 2026). Studio's shape: a row of big tiles, one black Upload button, and the
/// drafts underneath. Autocast's tiles are its own jobs -- plan a month, make
/// something with the AI, see every post -- and the sentence box stays, because
/// "say what to make and it starts" is the thing Studio does not have.
///
/// Drafts are the posts waiting for approval: the things started here that
/// have not gone anywhere yet.
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
    @State private var chatting = false
    @State private var browsing = false
    @State private var tips = TipGroup(.ordered) {
        PlanMonthTip()
        UploadTip()
    }
    @State private var approving: PendingPost?

    private var drafts: [PendingPost] { session.posts.filter(\.needsYou) }

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    CreateTile(symbol: "calendar.badge.plus", title: "Plan a month") { planning = true }
                        .popoverTip(tips.currentTip as? PlanMonthTip, arrowEdge: .top)
                    CreateTile(symbol: "sparkles", title: "Make with AI") { chatting = true }
                    CreateTile(symbol: "square.grid.2x2.fill", title: "All posts") { browsing = true }
                }
                .entrance(0)

                // TikTok-style: your video, your words, Write with AI, Post.
                NavigationLink { StudioFlowView() } label: {
                    PrimaryButtonLabel(title: "Upload", systemImage: "plus")
                }
                .primaryButtonStyle()
                .popoverTip(tips.currentTip as? UploadTip, arrowEdge: .top)
                .disabled(session.connections.isEmpty)
                .padding(.top, 18)
                .entrance(1)

                AskBox(text: $asked) { starting = true }
                    .padding(.top, 18)
                    .entrance(2)

                if !session.hasWorkingGenerator {
                    ConnectGeneratorRow()
                        .padding(.top, 12)
                        .entrance(3)
                }

                HStack {
                    Text("Drafts")
                        .font(.title2.bold())
                    Spacer()
                }
                .padding(.top, 28)

                if drafts.isEmpty {
                    DraftsEmpty()
                        .padding(.top, 12)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(drafts) { post in
                            NavigationLink { PostDetailView(postID: post.postId) } label: {
                                DraftTile(post: post)
                            }
                            .buttonStyle(SoftPressStyle())
                        }
                    }
                    .padding(.top, 12)
                }
            }
            .screenGutter()
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color.canvas.ignoresSafeArea())
        .navigationTitle("Create")
        .photosPicker(isPresented: $pickingVideo, selection: $pickerItem, matching: .videos)
        .task(id: pickerItem) { await loadPicked() }
        .refreshable { await session.refreshPosts() }
        .sheet(isPresented: $planning, onDismiss: {
            if proposed != nil { showingPlan = true }
        }) {
            NewPlanSheet(brief: "") { proposed = $0 }
        }
        .sheet(isPresented: $namingVideo) { captionSheet }
        .sheet(item: $approving) { ApprovalSheet(post: $0) }
        .navigationDestination(isPresented: $showingPlan) {
            PlanView(notice: proposed)
        }
        .navigationDestination(isPresented: $starting) {
            ChatView(opening: asked.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        .navigationDestination(isPresented: $chatting) {
            ChatView()
        }
        .navigationDestination(isPresented: $browsing) {
            LibraryView()
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

/// One of Studio's big tiles: the symbol on a white card, the name under it.
private struct CreateTile: View {
    let symbol: String
    let title: String
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 76)
                    .raisedCard(radius: Style.rowCard)

                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
    }
}

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

            // One box holds everything: the words, the examples to pick from
            // and the send button (Abel, 17 Sep: the choices sat outside it).
            VStack(alignment: .leading, spacing: 10) {
                TextField("A video about…", text: $text, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.body)
                    .focused($typing)
                    .submitLabel(.go)
                    .onSubmit { if ready { onStart() } }

                HStack(alignment: .center, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.examples, id: \.self) { example in
                                Button { text = example } label: {
                                    Text(example)
                                        .font(.footnote)
                                        .foregroundStyle(.primary)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(Color.raised))
                                        .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                                }
                                .buttonStyle(PressButtonStyle())
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .opacity(ready ? 0 : 1)
                    .allowsHitTesting(!ready)
                    .mask(
                        LinearGradient(stops: [.init(color: .black, location: 0.85), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    )

                    Button(action: onStart) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(ready ? Theme.onAccent : Color.secondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(ready ? Color.accentColor : Color.raised))
                    }
                    .buttonStyle(PressButtonStyle())
                    .disabled(!ready)
                    .accessibilityLabel("Start")
                }
            }
            .padding(12)
            .background(Color.track, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { typing = true }
            .animation(.easeOut(duration: 0.15), value: ready)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raisedCard(radius: Style.rowCard)
    }
}

/// Remi's coach card shape: an invitation, not a warning.
private struct ConnectGeneratorRow: View {
    var body: some View {
        NavigationLink { ProfileView().pushedPage() } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect a generator")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("So Autocast can make the videos too")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .raisedCard(radius: Style.rowCard)
        }
        .buttonStyle(SoftPressStyle())
    }
}

/// One draft, as Studio shows one: a picture area, then a line under it.
private struct DraftTile: View {
    let post: PendingPost

    private var title: String {
        let text = post.caption.isEmpty ? post.post.hook : post.caption
        return text.isEmpty ? "Untitled post" : text
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.track
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 140)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(post.state == .needsReapproval ? "Changed · review again" : "Waiting for you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
        .raisedCard(radius: Style.rowCard)
        .contentShape(RoundedRectangle(cornerRadius: Style.rowCard, style: .continuous))
    }
}

private struct DraftsEmpty: View {
    var body: some View {
        VStack(spacing: 8) {
            EmptyArt(name: "empty-posts", size: 96)
            Text("No drafts")
                .font(.headline)
            Text("What you plan or make waits here for your approval before it posts.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .raisedCard()
    }
}
