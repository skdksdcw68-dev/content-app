import SwiftUI

/// The screen TikTok's audit is really about.
///
/// Three things have to be true here and all three are checked again on the
/// server before anything is sent:
///
///   1. The creator can see whose account this is going to, by avatar and
///      handle, before they agree to anything.
///   2. The visibility is chosen from what the account currently offers -- read
///      from TikTok when this sheet opens, never from a list we hardcoded.
///   3. Restrictions the account already has are shown as unavailable rather
///      than as choices that will silently fail.
struct ApprovalSheet: View {
    let post: PendingPost

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var info: CreatorInfo?
    @State private var privacy: String?
    @State private var isAIGC = false
    @State private var disableComment = false
    @State private var disableDuet = false
    @State private var disableStitch = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    form(info)
                } else {
                    loading
                }
            }
            .navigationTitle(post.isApproved ? "Ready to post" : "Approve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Checking what your account allows")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func form(_ info: CreatorInfo) -> some View {
        Form {
            Section {
                CreatorHeader(info: info)
            } footer: {
                Text("This is the account it will be posted from.")
            }

            Section("Caption") {
                Text(post.caption.isEmpty ? post.post.hook : post.caption)
                    .font(.subheadline)
            }

            Section {
                // Built from what TikTok just said, not from a fixed list. An
                // unaudited app is not offered PUBLIC_TO_EVERYONE at all, which
                // is why it does not appear here.
                ForEach(info.privacyOptions, id: \.self) { option in
                    Button {
                        privacy = option
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CreatorInfo.label(for: option))
                                    .foregroundStyle(Color.primary)
                                Text(CreatorInfo.detail(for: option))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if privacy == option {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Who can see this")
            } footer: {
                if !info.privacyOptions.contains("PUBLIC_TO_EVERYONE") {
                    Text("Public posting is not available until TikTok has reviewed this app, so these are the options your account currently offers.")
                }
            }

            Section {
                Toggle("Made with AI", isOn: $isAIGC)
                Toggle("Turn off comments", isOn: $disableComment)
                    .disabled(info.commentDisabled)
                Toggle("Turn off Duet", isOn: $disableDuet)
                    .disabled(info.duetDisabled)
                Toggle("Turn off Stitch", isOn: $disableStitch)
                    .disabled(info.stitchDisabled)
            } header: {
                Text("Settings")
            } footer: {
                Text(restrictionNote(info))
            }

            Section {
                if post.isApproved {
                    Button {
                        Task { await send(draft: false) }
                    } label: {
                        Label("Post to TikTok", systemImage: "paperplane.fill")
                    }
                    Button {
                        Task { await send(draft: true) }
                    } label: {
                        Label("Send to my TikTok drafts", systemImage: "tray.and.arrow.down")
                    }
                } else {
                    Button {
                        Task { await approve() }
                    } label: {
                        Label("Approve this post", systemImage: "checkmark.shield")
                    }
                    .disabled(privacy == nil)
                }
            } footer: {
                Text(post.isApproved
                     ? "You approved this exact caption and video. If either changes, it stops and comes back to you."
                     : "Approving records what you agreed to. Nothing is posted until you press post.")
            }

            if let result {
                Section {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(session.isWorking)
        .overlay {
            if session.isWorking {
                ProgressView().controlSize(.large)
            }
        }
    }

    private func restrictionNote(_ info: CreatorInfo) -> String {
        var off: [String] = []
        if info.commentDisabled { off.append("comments") }
        if info.duetDisabled { off.append("Duet") }
        if info.stitchDisabled { off.append("Stitch") }

        guard !off.isEmpty else {
            return "Tell TikTok this was made with AI if any of it was generated."
        }
        return "Your account already has \(off.joined(separator: " and ")) turned off, so those cannot be changed here."
    }

    private func load() async {
        guard let connection = session.connections.first(where: \.isHealthy) else { return }
        let fetched = await session.creatorInfo(for: connection.id)
        info = fetched
        // Default to the most private option available rather than the widest.
        privacy = fetched?.privacyOptions.contains("SELF_ONLY") == true
            ? "SELF_ONLY"
            : fetched?.privacyOptions.first
        disableComment = fetched?.commentDisabled ?? false
        disableDuet = fetched?.duetDisabled ?? false
        disableStitch = fetched?.stitchDisabled ?? false
    }

    private func approve() async {
        guard let privacy else { return }
        let ok = await session.approve(
            postTargetID: post.id,
            privacy: privacy,
            disableComment: disableComment,
            disableDuet: disableDuet,
            disableStitch: disableStitch,
            isAIGC: isAIGC
        )
        if ok { dismiss() }
    }

    private func send(draft: Bool) async {
        let state = await session.publish(postTargetID: post.id, draft: draft)
        switch state {
        case "published":
            result = draft ? "It is in your TikTok drafts." : "Posted."
            dismiss()
        case "processing":
            result = "TikTok is still processing it. It will appear shortly."
        default:
            result = nil
        }
    }
}

/// Who this is going to. Avatar and handle, because TikTok requires the creator
/// be identifiable before a post and display names are routinely blank.
private struct CreatorHeader: View {
    let info: CreatorInfo

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: info.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 48, height: 48)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("@\(info.username)")
                    .font(.headline)
                Text("TikTok")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
