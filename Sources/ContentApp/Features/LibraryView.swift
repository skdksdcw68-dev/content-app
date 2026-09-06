import SwiftUI

/// Every asset the agent has made or been given.
struct LibraryView: View {
    var body: some View {
        ComingSoon(
            symbol: "square.grid.2x2",
            title: "Nothing made yet",
            detail: "Images and clips will collect here as they are generated, with a note of where each one came from, so anything without clear rights can be kept out of a post."
        )
        .navigationTitle("Library")
    }
}
