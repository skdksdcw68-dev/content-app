import SwiftUI

/// The person's picture: their initial in a circle, in Autocast's colours.
/// The account is the person, not a TikTok or YouTube face (Abel, 19 Sep 2026).
struct InitialAvatar: View {
    let initial: String
    var size: CGFloat = 40

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
            .accessibilityHidden(true)
    }
}
