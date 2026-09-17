import SwiftUI

/// What stands out about one video, and what to make next -- worked out on the
/// phone from the numbers `post_analytics` returned, never invented. Each line
/// compares this video with the account's own other videos; none claims to be
/// the cause.
struct PostObservation: Identifiable {
    enum Direction { case up, down, neutral, info }

    let id: String
    let direction: Direction
    let title: String
    let detail: String

    var symbol: String {
        switch direction {
        case .up:      "arrow.up.right.circle.fill"
        case .down:    "arrow.down.right.circle.fill"
        case .neutral: "equal.circle.fill"
        case .info:    "info.circle.fill"
        }
    }

    var tint: Color {
        switch direction {
        case .up:      .green
        case .down:    .red
        case .neutral: .secondary
        case .info:    .blue
        }
    }
}

struct PostNextStep {
    let title: String
    let detail: String
    let brief: String
}

enum PostInsights {
    static func ratio(_ value: Double, to median: Double?) -> Double? {
        guard let median, median > 0 else { return nil }
        return value / median
    }

    static func times(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1))))×"
    }

    /// Views gained between the last two hourly readings, and over how long.
    static func recentGrowth(_ readings: [PostAnalytics.Reading]) -> (views: Int, hours: Double)? {
        guard readings.count >= 2,
              let last = readings.last,
              let lastAt = PostgresTimestamp.parse(last.at),
              let previous = readings.dropLast().last,
              let previousAt = PostgresTimestamp.parse(previous.at) else { return nil }
        let hours = lastAt.timeIntervalSince(previousAt) / 3600
        guard hours > 0 else { return nil }
        return (last.views - previous.views, hours)
    }

    static func observations(_ data: PostAnalytics) -> [PostObservation] {
        let video = data.video
        guard let context = data.context else { return [] }
        var out: [PostObservation] = []

        if let r = ratio(Double(video.views), to: context.medianViews) {
            let median = AnalyticsFormat.number(context.medianViews ?? 0)
            let detail = "Your other \(context.others) videos have a median of \(median) views. This one ranks #\(context.rank) of \(context.videos)."
            if r >= 1.2 {
                out.append(.init(id: "views", direction: .up, title: "\(times(r)) your usual views", detail: detail))
            } else if r <= 0.8 {
                out.append(.init(id: "views", direction: .down, title: "\(times(r)) your usual views", detail: detail))
            } else {
                out.append(.init(id: "views", direction: .neutral, title: "About your usual views", detail: detail))
            }
        } else if context.others == 0 {
            out.append(.init(id: "views", direction: .info, title: "Your only video with numbers",
                             detail: "Comparisons start once Autocast has read another public video."))
        }

        if let rate = video.engagementRate, let usual = context.medianEngagement, usual > 0 {
            let line = "\(AnalyticsFormat.percent(rate)) of viewers liked, commented or shared, against \(AnalyticsFormat.percent(usual)) on your other videos."
            if rate >= usual * 1.2 {
                out.append(.init(id: "engagement", direction: .up, title: "People engaged more than usual", detail: line))
            } else if rate <= usual * 0.8 {
                out.append(.init(id: "engagement", direction: .down, title: "People engaged less than usual", detail: line))
            } else {
                out.append(.init(id: "engagement", direction: .neutral, title: "Usual engagement", detail: line))
            }
        }

        if let length = video.durationS, let usual = context.medianDuration, abs(Double(length) - usual) >= 5 {
            let longer = Double(length) > usual
            out.append(.init(
                id: "length",
                direction: .info,
                title: longer ? "Longer than your usual" : "Shorter than your usual",
                detail: "\(length)s, against about \(Int(usual.rounded()))s for your other videos."
            ))
        }

        if let hour = context.postedHour {
            let posted = AnalyticsFormat.clock(hour)
            if let best = context.bestHour {
                let inBest = hour >= best.slot && hour < best.slot + 3
                out.append(.init(
                    id: "time",
                    direction: inBest ? .up : .info,
                    title: inBest ? "Posted in your best time block" : "Posted at \(posted)",
                    detail: inBest
                        ? "Your videos posted \(AnalyticsFormat.hourBlock(best.slot)) get \(AnalyticsFormat.signedPercent(best.lift)) more views (across \(best.posts))."
                        : "Your videos posted \(AnalyticsFormat.hourBlock(best.slot)) do best: \(AnalyticsFormat.signedPercent(best.lift)) views across \(best.posts)."
                ))
            } else {
                out.append(.init(
                    id: "time",
                    direction: .info,
                    title: "Posted at \(posted)",
                    detail: "Autocast needs 8 videos with numbers before it can say which hours work best for you."
                ))
            }
        }

        if let tags = context.hashtags, let usual = context.medianHashtags, abs(Double(tags) - usual) >= 2 {
            out.append(.init(
                id: "hashtags",
                direction: .info,
                title: Double(tags) > usual ? "More hashtags than usual" : "Fewer hashtags than usual",
                detail: "\(tags) hashtags, against about \(Int(usual.rounded())) on your other videos."
            ))
        }

        if let length = context.captionLength, let usual = context.medianCaptionLength, abs(Double(length) - usual) >= 30 {
            out.append(.init(
                id: "caption",
                direction: .info,
                title: Double(length) > usual ? "Longer caption than usual" : "Shorter caption than usual",
                detail: "\(length) characters, against about \(Int(usual.rounded())) on your others."
            ))
        }

        if let hours = context.hoursLive, hours < 48 {
            var detail = "It has been live \(liveFor(hours)), so these numbers are still moving."
            if let growth = recentGrowth(data.readings ?? []) {
                detail += " +\(growth.views) views in the last \(liveFor(growth.hours))."
            }
            out.append(.init(id: "age", direction: .info, title: "Still new", detail: detail))
        }

        return out
    }

    static func nextStep(_ data: PostAnalytics, title: String) -> PostNextStep {
        let video = data.video
        let context = data.context
        let length = video.durationS.map { "\($0)s" } ?? "the same length"
        let r = ratio(Double(video.views), to: context?.medianViews)

        if let r, r >= 1.2 {
            return PostNextStep(
                title: "Make another like this",
                detail: "It beat your usual views \(times(r)). Keep what worked and change the example.",
                brief: "Make a variation of our video \"\(title)\": same style and length (about \(length)), same kind of hook, a new example."
            )
        }
        if let r, r <= 0.8 {
            let usual = context?.medianDuration.map { "about \(Int($0.rounded()))s" } ?? "your usual length"
            return PostNextStep(
                title: "Try a stronger opening",
                detail: "It got \(times(r)) your usual views. Keep the topic, change the first two seconds and aim for \(usual).",
                brief: "Remake the idea behind \"\(title)\" with a stronger hook in the first two seconds, around \(usual)."
            )
        }
        return PostNextStep(
            title: "Test one change",
            detail: "It did about as well as usual. Change one thing next time -- the hook or the length -- so the result tells you something.",
            brief: "Make a follow-up to \"\(title)\" that changes only the opening hook, so we can compare."
        )
    }

    static func liveFor(_ hours: Double) -> String {
        if hours < 1 { return "\(max(1, Int((hours * 60).rounded()))) min" }
        if hours < 48 { return "\(Int(hours.rounded())) h" }
        return "\(Int((hours / 24).rounded())) days"
    }
}
