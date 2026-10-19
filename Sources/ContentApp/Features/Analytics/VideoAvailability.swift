import SwiftUI

/// A video TikTok no longer lists publicly, said as such instead of as views.
///
/// Netro, 19 Oct 2026: a deleted or private video "still shows the views. It
/// doesn't show that the video is unavailable or deleted" -- so people read it
/// as live and doing well. TikTok's API only lists public videos and does not
/// say which of deleted, private or removed it was (0083), so neither do we.

extension AppSession {
    func isUnavailable(_ videoId: String) -> Bool {
        unavailableVideoIDs.contains(videoId)
    }
}

/// In place of the view count on a tile or a row.
struct UnavailableTag: View {
    /// White on a thumbnail's dark gradient; secondary on a plain row.
    var onDark = false

    var body: some View {
        Label("Unavailable", systemImage: "eye.slash")
            .font(.caption.weight(.bold))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(onDark ? AnyShapeStyle(.white) : AnyShapeStyle(Color.orange))
            .accessibilityLabel("Unavailable. Deleted, made private, or removed by TikTok")
    }
}

/// Above a video's numbers, on its own page.
struct UnavailableNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "eye.slash.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("This video is no longer public")
                    .font(.subheadline.weight(.semibold))
                Text("It was deleted, made private, or removed by TikTok. The numbers below are the last ones it had.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
