import SwiftUI

/// What is left this month, as the first row of the Credits section: the number
/// big, and a bar that is the same fact drawn.
///
/// Netro, 13 Oct 2026: "Credits Used" and "Credits Left" were two tiles in a row
/// under the name. Numbers in a row say nothing about how much of the month is
/// gone. A bar does, and the figures that go with it read better as list rows
/// below it than as more tiles.
///
/// Until the standing is read this draws an ellipsis, never a zero: a zero is a
/// claim (see the note on `AppSession.refreshCredits`).
struct CreditsMeter: View {
    let credits: CreditsStanding?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(credits.map { CreditFormat.text($0.left) } ?? "…")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("credits left")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            // A bar only where there is a month's allowance to measure against.
            if let credits, credits.allowance > 0 {
                ProgressView(value: credits.fractionLeft)
                    .tint(Theme.accent)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Credits left")
        .accessibilityValue(credits.map { CreditFormat.text($0.left) } ?? "Loading")
    }
}

/// One network in the Accounts list: its mark on a tile, its name over the
/// handle, and what to do on the right.
///
/// Netro, 13 Oct 2026: the connected accounts were a row of small capsules and
/// read as boring. A list row says more -- who, which network, and whether it
/// needs attention -- and takes the whole width to say it.
///
/// There is no "Connected" label on purpose. A handle under the name already
/// says so, and a green CONNECTED pill is something Abel has asked to be rid
/// of (15 Sep 2026). Only the exceptions are worded.
struct AccountRow: View {
    let platform: Platform
    /// nil when this network has not been connected yet.
    let connection: PlatformConnection?
    /// True while its sign-in is opening, so the word can say so.
    var opening = false

    var body: some View {
        HStack(spacing: 12) {
            platform.logo.view
                .frame(width: 22, height: 22)
                .frame(width: 40, height: 40)
                .background(
                    Color(uiColor: .tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(platform.networkName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(connection?.label ?? "Not connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var trailing: some View {
        if let connection {
            if !connection.isHealthy {
                Label("Sign in again", systemImage: "exclamationmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.orange)
            }
        } else {
            Text(opening ? "Opening…" : "Connect")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
        }
    }
}
