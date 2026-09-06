import SwiftUI

/// One honest empty state, used by every surface that has nothing behind it yet.
///
/// It names what is missing and why, instead of showing a spinner or a grid of
/// placeholder tiles. The version of this app that shipped sample data taught
/// nobody anything about whether it worked.
struct ComingSoon: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
                .frame(width: 72, height: 72)
                .background(Theme.softAccent, in: Circle())

            Text(title)
                .font(.headline)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
