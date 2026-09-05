import Foundation

/// One topic's results, ranked. Identifiable so the bars can be a ForEach.
struct TopicPerformance: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let views: Int
    let postCount: Int
}

/// Average views for everything published in a given hour of the day.
struct HourPerformance: Identifiable, Hashable, Sendable {
    var id: Int { hour }
    let hour: Int
    let averageViews: Int
    let postCount: Int

    var label: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Something the app noticed and thinks is worth doing. Derived from posted
/// results only -- a recommendation with no evidence behind it is a horoscope.
struct Recommendation: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let symbolName: String
}

/// Everything Home and Insights read.
///
/// All of it is derived from `posts`, so there is no second source of truth to
/// keep in step. A metric with nothing behind it comes back nil rather than
/// zero, because "not reported" and "nobody did it" are different facts and
/// the tiles render them differently.
extension ContentStore {

    // MARK: - Home

    /// Posts due or already out today, earliest first.
    var todaysPosts: [ContentPost] {
        let calendar = Calendar.current
        return posts
            .filter { post in
                guard let date = post.postedAt ?? post.scheduledFor else { return false }
                return calendar.isDateInToday(date)
            }
            .sorted {
                ($0.postedAt ?? $0.scheduledFor ?? .distantFuture)
                    < ($1.postedAt ?? $1.scheduledFor ?? .distantFuture)
            }
    }

    /// How much of today is actually done. Nil when nothing is due today, so
    /// the card says "nothing scheduled" instead of showing a hollow 0%.
    var todayCompletion: Double? {
        let todays = todaysPosts
        guard !todays.isEmpty else { return nil }
        let done = todays.filter { $0.status == .posted }.count
        return Double(done) / Double(todays.count)
    }

    var todayPostedCount: Int {
        todaysPosts.filter { $0.status == .posted }.count
    }

    /// The next things the autopilot owes you, soonest first.
    var upcomingPosts: [ContentPost] {
        posts
            .filter { !$0.status.isTerminal }
            .sorted { ($0.scheduledFor ?? .distantFuture) < ($1.scheduledFor ?? .distantFuture) }
    }

    /// The most recently published posts, newest first.
    var recentlyPosted: [ContentPost] {
        posts
            .filter { $0.status == .posted }
            .sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
    }

    /// The single line Home leads with.
    ///
    /// Ordered by urgency: something broke, then something needs you, then
    /// something learned, then reassurance. Only one is ever shown, so the
    /// order is the whole design.
    var homeInsight: Recommendation {
        if let failed = posts.first(where: { $0.status == .failed }) {
            return Recommendation(
                id: "failed",
                text: failed.failureReason.map { "A post failed: \($0)" }
                    ?? "A post failed and needs a look.",
                symbolName: "exclamationmark.triangle"
            )
        }

        if awaitingApprovalCount > 0 {
            let subject = awaitingApprovalCount == 1 ? "post is" : "posts are"
            return Recommendation(
                id: "approval",
                text: "\(awaitingApprovalCount) \(subject) written and waiting on you.",
                symbolName: "hand.raised"
            )
        }

        if let best = bestHours.first, best.postCount > 1 {
            let views = best.averageViews.formatted(.number.notation(.compactName))
            return Recommendation(
                id: "hour",
                text: "Your \(best.label) slot averages \(views) views, the best of any hour you post in.",
                symbolName: "clock"
            )
        }

        if !settings.isOn {
            return Recommendation(
                id: "off",
                text: "Autopilot is off, so nothing is being planned.",
                symbolName: "pause.circle"
            )
        }

        return Recommendation(
            id: "steady",
            text: "Nothing needs you. \(upcomingPosts.count) posts are queued and on schedule.",
            symbolName: "checkmark.circle"
        )
    }

    // MARK: - Insights

    var postedPosts: [ContentPost] {
        posts.filter { $0.status == .posted }
    }

    var publishedCount: Int { postedPosts.count }

    var totalViews: Int? { sum(\.views) }
    var totalLikes: Int? { sum(\.likes) }
    var totalSaves: Int? { sum(\.saves) }
    var totalShares: Int? { sum(\.shares) }

    /// Nil when no published post reported this metric at all.
    private func sum(_ metric: KeyPath<ContentPost, Int?>) -> Int? {
        let values = postedPosts.compactMap { $0[keyPath: metric] }
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// Interactions over views, averaged across everything published.
    var averageEngagement: Double? {
        let rates = postedPosts.compactMap(\.engagementRate)
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }

    /// Pillars ranked by the views they actually earned, best first.
    var topTopics: [TopicPerformance] {
        var totals: [UUID: (views: Int, count: Int)] = [:]

        for post in postedPosts {
            guard let pillarID = post.pillarID else { continue }
            let running = totals[pillarID] ?? (views: 0, count: 0)
            totals[pillarID] = (running.views + (post.views ?? 0), running.count + 1)
        }

        return totals
            .compactMap { pillarID, running -> TopicPerformance? in
                guard let pillar = pillars.first(where: { $0.id == pillarID }) else { return nil }
                return TopicPerformance(
                    id: pillarID,
                    name: pillar.name,
                    views: running.views,
                    postCount: running.count
                )
            }
            .sorted { $0.views > $1.views }
    }

    /// The hooks that worked, best first. The caller decides how many to show.
    var bestHooks: [ContentPost] {
        postedPosts
            .filter { $0.views != nil }
            .sorted { ($0.views ?? 0) > ($1.views ?? 0) }
    }

    /// Publishing hours ranked by average views. Only hours that actually have
    /// a post in them appear, so this never recommends a time never tried.
    var bestHours: [HourPerformance] {
        let calendar = Calendar.current
        var buckets: [Int: [Int]] = [:]

        for post in postedPosts {
            guard let postedAt = post.postedAt, let views = post.views else { continue }
            buckets[calendar.component(.hour, from: postedAt), default: []].append(views)
        }

        return buckets
            .map { hour, views in
                HourPerformance(
                    hour: hour,
                    averageViews: views.reduce(0, +) / views.count,
                    postCount: views.count
                )
            }
            .sorted { $0.averageViews > $1.averageViews }
    }

    /// Which platform is carrying the account, by average views per post.
    /// On this app the platform is the format -- a Short and a TikTok are cut
    /// differently even when the script is the same.
    var bestFormat: HourPerformanceFormat? {
        var buckets: [Platform: [Int]] = [:]

        for post in postedPosts {
            guard let views = post.views else { continue }
            buckets[post.platform, default: []].append(views)
        }

        return buckets
            .map { platform, views in
                HourPerformanceFormat(
                    platform: platform,
                    averageViews: views.reduce(0, +) / views.count,
                    postCount: views.count
                )
            }
            .sorted { $0.averageViews > $1.averageViews }
            .first
    }

    /// What to do next, each line tied to something in the data above.
    /// Empty until there is enough published work to say anything honest.
    var recommendations: [Recommendation] {
        var result: [Recommendation] = []

        let topics = topTopics
        if topics.count > 1, let top = topics.first, let worst = topics.last,
           worst.views > 0, top.views > worst.views * 2 {
            result.append(Recommendation(
                id: "topic",
                text: "\(top.name) outperforms \(worst.name) by more than 2x. Weight it higher in Profile.",
                symbolName: "chart.bar"
            ))
        }

        let hours = bestHours
        if hours.count > 1, let best = hours.first, let worst = hours.last {
            let bestViews = best.averageViews.formatted(.number.notation(.compactName))
            let worstViews = worst.averageViews.formatted(.number.notation(.compactName))
            result.append(Recommendation(
                id: "time",
                text: "Posts at \(best.label) average \(bestViews) views against \(worstViews) at \(worst.label).",
                symbolName: "clock"
            ))
        }

        if let hook = bestHooks.first, let views = hook.views {
            let formatted = views.formatted(.number.notation(.compactName))
            result.append(Recommendation(
                id: "hook",
                text: "\u{201C}\(hook.hook)\u{201D} did \(formatted). Openings that name a cost do best here.",
                symbolName: "text.quote"
            ))
        }

        if let off = pillars.first(where: { !$0.isEnabled }), publishedCount > 1 {
            result.append(Recommendation(
                id: "pillar",
                text: "\(off.name) is switched off, so nothing is being planned from it.",
                symbolName: "circle.slash"
            ))
        }

        return result
    }
}

/// One platform's average result. Named separately rather than returned as a
/// tuple so it can be used in a ForEach and in a `let` without repeating the
/// shape at every call site.
struct HourPerformanceFormat: Identifiable, Hashable, Sendable {
    var id: Platform { platform }
    let platform: Platform
    let averageViews: Int
    let postCount: Int
}
