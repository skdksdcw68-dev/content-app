import SwiftUI

/// Where the day is.
///
/// It has nothing to show yet because nothing plans anything yet, and it says
/// so. An empty state that tells the truth is more useful than one filled with
/// sample data, which is what the previous version of this app did and why
/// nobody could tell what worked.
struct HomeView: View {
    @Environment(AppSession.self) private var session
    /// Increments when Home is tapped while already open.
    let scrollToTop: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Color.clear.frame(height: 0).id(Anchor.top)

                    if session.connections.isEmpty {
                        ConnectFirstCard()
                    } else {
                        ReadyCard(handle: session.connections.first?.label ?? "")
                    }

                    NothingPlannedCard()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 96)
            }
            .onChange(of: scrollToTop) {
                withAnimation(.snappy) { proxy.scrollTo(Anchor.top, anchor: .top) }
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Home")
        .refreshable { await session.refreshConnections() }
    }

    private enum Anchor { case top }
}

private struct ConnectFirstCard: View {
    var body: some View {
        Card("Start here", systemImage: "link") {
            Text("Connect a TikTok account and Autocast can start planning for it. Nothing is published without your say-so.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("You → Connect TikTok")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
    }
}

private struct ReadyCard: View {
    let handle: String

    var body: some View {
        Card("Connected", systemImage: "checkmark.circle") {
            Text("\(handle) is linked and Autocast can post to it once you approve something.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct NothingPlannedCard: View {
    var body: some View {
        Card("Today", systemImage: "sun.max") {
            Text("Nothing is scheduled. Planning arrives with Chat, which is the next thing being built.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
