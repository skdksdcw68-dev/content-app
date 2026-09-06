import SwiftUI

/// Where the agent will live.
///
/// Deliberately empty rather than a fake conversation. The whole point of the
/// rebuild is that the app stops pretending, so a screen with nothing behind it
/// says so plainly and names what it is waiting on.
struct ChatView: View {
    var body: some View {
        ComingSoon(
            symbol: "bubble.left.and.sparkles",
            title: "Ask for a month of content",
            detail: "You will describe what you want here and it will plan up to thirty days, write the captions and book the slots. Until the agent is wired up, Library is where you add a video and Home is where you approve it -- both of those work today."
        )
        .navigationTitle("Chat")
    }
}
