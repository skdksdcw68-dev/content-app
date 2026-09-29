import SwiftUI

/// The generator's history, drawn the way ElevenLabs draws theirs.
///
/// Abel, 26 Sep 2026, on being asked whether the video page should keep chat's
/// bubbles or match his screenshots exactly: "yes i said."
///
/// So: no bubbles. Each generation is a block — the KIND in small grey, a
/// copy-back and a retry control on the right, the prompt in plain ink with
/// its frame chips beside it, and the result underneath. Newest at the top,
/// which is where his screenshots put it: the thing counting up is the thing
/// you are waiting for, and it should not be under a keyboard's worth of
/// history.
///
/// The agent's own sentences ("Making Hi.") are not drawn. The block's shape
/// says all of that — a placeholder counting up IS "making it". The one
/// assistant text that survives is a failure, because an error nobody can see
/// is a generation that silently never arrived, which this project has had
/// enough of.
struct GenerationFeed: View {
    let turns: [ChatMessage]
    /// Puts the prompt back in the composer for editing.
    let onCopy: (String) -> Void
    /// Runs the same prompt again with the composer's current choices.
    let onRetry: (String) -> Void
    /// A picture made here, set up in the composer to make a video from.
    ///
    /// 🔴 Nothing was wired to this. The feed drew its cards with the default
    /// no-op closures, so on the video page the viewer's Animate button was
    /// there, pressed, and did nothing at all (Abel, 29 Sep 2026: "when you
    /// are trying to use an image for a video preference... it's not going to
    /// attach it, and it's not going to use it").
    let onAnimate: (Artifact) -> Void
    /// A picture made here, set up in the composer as a reference.
    let onReference: (Artifact) -> Void

    @Environment(AppSession.self) private var session

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(entries.reversed()) { entry in
                block(entry)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - One generation

    @ViewBuilder
    private func block(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 18) {
                Text(entry.kind)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { onCopy(entry.prompt) } label: {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit this prompt")
                Button { onRetry(entry.prompt) } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Make it again")
            }

            HStack(alignment: .center, spacing: 8) {
                // The frames it was given, as small chips before the words,
                // exactly where the screenshots put them.
                ForEach(entry.attachments.prefix(3), id: \.self) { path in
                    AttachmentChip(path: path)
                }
                Text(entry.prompt)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let artifactId = entry.artifactId {
                ArtifactCard(
                    artifactId: artifactId,
                    expect: (entry.artifactKind, entry.width, entry.height),
                    onAnimate: onAnimate,
                    onReference: onReference
                )
                .padding(.top, 6)
            } else if entry.pending && entry.isSmallTalk {
                // A greeting is answered, not made: a breathing dot while the
                // reply is on its way, not a video-shaped box counting up.
                BreathingDot(size: 9)
                    .padding(.top, 2)
            } else if entry.pending {
                // Counting, in an empty 9:16 card about half the screen wide
                // -- the number and nothing else.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface)
                    .frame(width: 200, height: 356)
                    .overlay { MakingSheen() }
                    .overlay { MakingProgress(expected: MakingProgress.expected(for: entry.expectedKind)) }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 6)
            } else if let failure = entry.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            } else if let reply = entry.reply {
                // What the agent said back to a greeting: "Sure, what should
                // the video be of?" Plain ink, under what was said, with no
                // warning on it -- it is not an error.
                Text(reply)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .textSelection(.enabled)
            }
        }
    }

    /// A small round thumbnail of an attached picture.
    private struct AttachmentChip: View {
        let path: String
        @Environment(AppSession.self) private var session
        @State private var image: UIImage?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.track
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: path) {
                if image == nil { image = await session.attachmentThumbnail(path, longest: 64) }
            }
        }
    }

    // MARK: - Reading the transcript

    struct Entry: Identifiable {
        let id: UUID
        var prompt: String
        var attachments: [String]
        var artifactId: UUID?
        var artifactKind: String?
        var width: Int?
        var height: Int?
        var pending = false
        var failure: String?
        /// The agent's answer to a greeting -- text, not a result.
        var reply: String?
        var expectedKind: String?

        /// Said TO the assistant rather than describing something to make.
        var isSmallTalk: Bool { SmallTalk.matches(prompt) }

        var kind: String {
            // A greeting and its answer are a chat, and say so; labelling
            // "Hi" as a Video is what made the page look like it had made one.
            if isSmallTalk && artifactId == nil { return "Chat" }
            switch artifactKind ?? expectedKind {
            case "image": return "Image"
            case "audio": return "Audio"
            default: return "Video"
            }
        }
    }

    /// The transcript folded into generations: each of the person's turns,
    /// with whatever the turns after it produced. The writer's prose is
    /// dropped — the one sentence kept is the last one of an attempt that
    /// produced nothing, which is the error.
    private var entries: [Entry] {
        var out: [Entry] = []
        for turn in turns {
            switch turn.role {
            case .user:
                out.append(Entry(
                    id: turn.id,
                    prompt: Self.stripped(turn.text),
                    attachments: turn.attachments
                ))
            case .assistant:
                guard var current = out.last else { continue }
                if let made = turn.artifactId {
                    current.artifactId = made
                    current.artifactKind = turn.artifactKind
                    current.width = turn.artifactWidth
                    current.height = turn.artifactHeight
                    current.pending = false
                    current.failure = nil
                } else if turn.isPending {
                    current.pending = true
                    current.expectedKind = turn.artifactKind ?? current.expectedKind
                } else if turn.failed || !turn.text.isEmpty {
                    // Kept only while nothing has arrived; replaced by the
                    // result when one does. "Making Hi." never survives a
                    // finished video, and an error never disappears under one
                    // that did not come.
                    if current.artifactId == nil {
                        current.pending = false
                        if !turn.failed, current.isSmallTalk {
                            // The answer to "Hi" is an answer, not a fault.
                            current.reply = turn.text
                            current.failure = nil
                        } else {
                            current.failure = turn.failed || !Self.isChatter(turn.text) ? turn.text : nil
                        }
                    }
                }
                out[out.count - 1] = current
            }
        }
        return out
    }

    /// The composer's old habit of appending "(5 seconds, 9:16, ...)" to the
    /// prompt. Not drawn: the person wrote the words before the bracket.
    private static func stripped(_ text: String) -> String {
        guard let opening = text.range(of: "\n(", options: .backwards),
              text.hasSuffix(")") else { return text }
        return String(text[..<opening.lowerBound])
    }

    /// The writer narrating ("Making a reaction video."), as opposed to
    /// telling somebody something went wrong. Narration starts with what it
    /// is doing; errors talk about the person's account, credits or
    /// connections — kept, because hiding those is how three weeks were lost.
    private static func isChatter(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("making ") || lowered.hasPrefix("sure")
            || lowered.hasPrefix("ready to make") || lowered.hasPrefix("here's your")
            || lowered.hasPrefix("glad you")
    }
}
