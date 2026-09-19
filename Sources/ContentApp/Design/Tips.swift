import SwiftUI
import TipKit

// First-time help, with an arrow at the thing it explains.
//
// Abel, 17 Sep 2026: "for new people teach the buttons, like with an arrow,
// what the button is for, for the first time." Apple's TipKit is exactly that
// and native: a popover pointing at the control, shown once, gone for good
// when dismissed or when the control is used. Each screen shows its tips one
// at a time (`TipGroup(.ordered)`), never a wall of them.

enum AppTips {
    /// Called once at launch.
    static func configure() {
        try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault),
        ])
    }
}

// MARK: - Home

struct CreateTip: Tip {
    var title: Text { Text("Start here") }
    var message: Text? { Text("Tell Autocast what to post, plan a whole month, or upload a video.") }
    var image: Image? { Image(systemName: "plus.circle.fill") }
}

// MARK: - Analytics

struct PostsLibraryTip: Tip {
    var title: Text { Text("Your posts") }
    var message: Text? { Text("Every video, laid out like your TikTok profile. Tap one to see how it did.") }
    var image: Image? { Image(systemName: "square.grid.3x3") }
}

struct RangeTip: Tip {
    var title: Text { Text("Pick the dates") }
    var message: Text? { Text("Switch between 7, 28, 60 and 365 days, or choose your own range with Custom.") }
    var image: Image? { Image(systemName: "calendar") }
}

struct FilterTip: Tip {
    var title: Text { Text("Filter") }
    var message: Text? { Text("Narrow the numbers to one platform, format, theme or campaign.") }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }
}

struct ExportTip: Tip {
    var title: Text { Text("Export") }
    var message: Text? { Text("Save what you're looking at as a CSV or a PDF report.") }
    var image: Image? { Image(systemName: "square.and.arrow.up") }
}

// MARK: - Create

struct PlanMonthTip: Tip {
    var title: Text { Text("Plan a month") }
    var message: Text? { Text("Autocast writes up to 30 days of posts. You approve before anything goes out.") }
    var image: Image? { Image(systemName: "calendar.badge.plus") }
}

struct UploadTip: Tip {
    var title: Text { Text("Upload") }
    var message: Text? { Text("Add a video you already made. It waits for your approval.") }
    var image: Image? { Image(systemName: "arrow.up.circle") }
}

// MARK: - Chat

struct ChatStartTip: Tip {
    var title: Text { Text("Talk to Autocast") }
    var message: Text? { Text("Ask it to plan, research, make a picture or video, or explain your numbers.") }
    var image: Image? { Image(systemName: "sparkles") }
}

struct ReplyActionsTip: Tip {
    var title: Text { Text("Rate the answer") }
    var message: Text? { Text("Copy it, like or dislike it, or ask for a new one. Your ratings help Autocast improve.") }
    var image: Image? { Image(systemName: "hand.thumbsup") }
}
