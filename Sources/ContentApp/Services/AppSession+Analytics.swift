import Foundation
import Supabase

/// Analytics, learning and recommendations, read from the server.
///
/// Everything here is a read of something the server computed from real
/// readings (0039): `analytics_report`, `post_analytics`, `autopilot_report`,
/// and the `insights` / `recommendations` the learning job writes. The app
/// never computes a finding of its own, so the screen, Chat and the exported
/// file cannot disagree.
///
/// Decoded with snake_case conversion from the raw response, and every value
/// the server can leave null is optional here -- "not reported" must survive
/// all the way to the screen as a dash, never become a zero.

/// What is being asked for: a date range and the filters on it.
struct AnalyticsQuery: Equatable, Sendable {
    var from: Date
    var to: Date
    var platform: String?
    var format: String?
    var pillarId: UUID?
    var planId: UUID?

    var isFiltered: Bool { format != nil || pillarId != nil || planId != nil }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

enum AnalyticsDay {
    /// "2026-09-15" as a date at local midnight.
    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(text.prefix(10)))
    }
}

// MARK: - The report

struct AnalyticsReport: Decodable, Sendable {
    struct Range: Decodable, Sendable {
        let from: String
        let to: String
        let prevFrom: String
        let prevTo: String
        let step: Int
        let grain: String
    }

    /// One period's gains. `unknown` counts videos whose gain could not be
    /// computed because Autocast had no reading yet at the start.
    struct Totals: Decodable, Sendable {
        let views: Int?
        let likes: Int?
        let comments: Int?
        let shares: Int?
        let followers: Int?
        let videos: Int
        let unknown: Int
        let accounts: Int
        let followersUnknown: Int
        /// Videos counted from their first reading inside the period, because
        /// Autocast was not reading yet when it started (0040).
        let partialVideos: Int?
        let countedFrom: String?
        let followersPartial: Int?
        let followersCountedFrom: String?
    }

    struct PeriodTotals: Decodable, Sendable {
        let current: Totals?
        let previous: Totals?
    }

    struct Bucket: Decodable, Sendable {
        let period: String
        let idx: Int
        let start: String
        let end: String
        let views: Int?
        let likes: Int?
        let comments: Int?
        let shares: Int?
        let followers: Int?
        let videos: Int
        let unknown: Int
        let accounts: Int
        let followersUnknown: Int
    }

    struct Video: Decodable, Sendable, Identifiable, Hashable {
        var id: String { videoId }
        let videoId: String
        let title: String?
        let description: String?
        let coverUrl: String?
        let shareUrl: String?
        let platform: String
        let postedAt: String?
        let durationS: Int?
        let views: Int
        let likes: Int
        let comments: Int
        let shares: Int
        let engagementRate: Double?
        let relative: Double?
        let postId: UUID?
        let format: String?
        let pillar: String?
        let campaign: String?
        let hook: String?
        let fromAutocast: Bool

        var displayTitle: String {
            for text in [hook, title, description] {
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
            }
            return "Untitled"
        }
    }

    struct Slot: Decodable, Sendable {
        let slot: Int
        let posts: Int
        let medianViews: Double
    }

    struct Pick: Decodable, Sendable {
        let slot: Int
        let posts: Int
        let medianViews: Double
        let lift: Double
        let confidence: String?
    }

    struct BestTime: Decodable, Sendable {
        let videos: Int
        let minimum: Int
        let overallMedian: Double?
        let hours: [Slot]
        let days: [Slot]
        let bestHours: Pick?
        let bestDay: Pick?
    }

    struct Group: Decodable, Sendable {
        let dimension: String
        let label: String?
        let posts: Int
        let medianViews: Double?
        let medianEngagement: Double?
    }

    struct Option: Decodable, Sendable, Hashable, Identifiable {
        let id: UUID
        let name: String
    }

    struct Filters: Decodable, Sendable {
        let formats: [String]
        let pillars: [Option]
        let campaigns: [Option]
    }

    struct Campaign: Decodable, Sendable, Identifiable {
        let id: UUID
        let title: String
        let status: String
        let startsOn: String
        let days: Int
        let posts: Int
        let published: Int
        let videos: Int
        let views: Int?
        let likes: Int?
        let comments: Int?
        let shares: Int?
    }

    let status: String
    let timezone: String
    let range: Range
    let historyStarts: String?
    let platforms: [String]
    let availability: [String: String]
    let filtered: Bool
    /// The latest follower count Autocast read, so the total never depends on
    /// a live call succeeding.
    let followersTotal: Int?
    let totals: PeriodTotals
    let series: [Bucket]
    let videos: Int
    let medianViews: Double?
    let topScope: String
    let top: [Video]
    let bestTime: BestTime
    let breakdowns: [Group]
    let filters: Filters
    let campaigns: [Campaign]
}

// MARK: - The library

/// Every video on the brand's accounts, for the profile-style grid.
struct PostsLibrary: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let followers: Int?
        let likes: Int?
        let videoCount: Int?
    }

    struct Video: Decodable, Sendable, Identifiable, Hashable {
        var id: String { videoId }
        let videoId: String
        let platform: String
        let title: String?
        let coverUrl: String?
        let shareUrl: String?
        let postedAt: String?
        let durationS: Int?
        let views: Int
        let likes: Int
        let comments: Int
        let shares: Int
        let fromAutocast: Bool
    }

    let account: Account
    let videos: [Video]
}

// MARK: - One post

struct PostAnalytics: Decodable, Sendable {
    struct Video: Decodable, Sendable {
        let videoId: String
        let platform: String
        let title: String?
        let description: String?
        let coverUrl: String?
        let shareUrl: String?
        let durationS: Int?
        let postedAt: String?
        let measuredAt: String?
        let views: Int
        let likes: Int
        let comments: Int
        let shares: Int
        let engagementRate: Double?
        let fromAutocast: Bool
    }

    struct Day: Decodable, Sendable {
        let day: String
        let views: Int
        let likes: Int
        let comments: Int
        let shares: Int
    }

    struct Post: Decodable, Sendable {
        let hook: String?
        let caption: String?
        let concept: String?
        let rationale: String?
        let format: String?
        let pillar: String?
        let campaign: String?
        let hashtags: [String]?
        let mediaStrategy: String?
        let privacy: String?
        let scheduledFor: String?
        let publishedAt: String?
    }

    struct Media: Decodable, Sendable {
        let kind: String?
        let source: String?
        let provider: String?
        let model: String?
        let durationMs: Int?
        let width: Int?
        let height: Int?
    }

    struct Comparison: Decodable, Sendable {
        let scope: String
        let label: String
        let posts: Int
        let medianViews: Double?
        let medianEngagement: Double?
    }

    let video: Video
    let availability: [String: String]
    let daily: [Day]
    let post: Post?
    let media: [Media]
    let comparisons: [Comparison]
}

// MARK: - Autopilot

struct AutopilotReport: Decodable, Sendable {
    struct Reason: Decodable, Sendable {
        let code: String
        let count: Int
    }

    struct Side: Decodable, Sendable {
        let posts: Int
        let medianViews: Double?
    }

    let isOn: Bool
    let jobs: Int
    let succeeded: Int
    let failed: Int
    let cancelled: Int
    let inProgress: Int
    let avgGenerationSeconds: Double?
    let costCents: Int?
    let costReportedJobs: Int
    let failureReasons: [Reason]
    let planned: Int
    let published: Int
    let waitingApproval: Int
    let compare: [String: Side]

    /// Of the jobs that finished, how many worked. Nil until one finished.
    var successRate: Double? {
        let finished = succeeded + failed
        return finished > 0 ? Double(succeeded) / Double(finished) : nil
    }
}

// MARK: - Learning

struct Insight: Decodable, Sendable, Identifiable {
    struct Evidence: Decodable, Sendable {
        struct Side: Decodable, Sendable {
            let label: String
            let posts: Int
            let medianViews: Double
        }
        let winner: Side?
        let loser: Side?
        let liftWithoutTopVideo: Double?
        let rule: String?
    }

    let id: UUID
    let key: String
    let statement: String
    let metric: String
    let lift: Double
    let sampleSize: Int
    let confidence: String
    let evidence: Evidence
    let periodStart: String?
    let periodEnd: String?
    let platforms: [String]
    let contentTypes: [String]
}

struct Recommendation: Decodable, Sendable, Identifiable {
    struct Action: Decodable, Sendable {
        let fact: String?
        let brief: String?
    }

    let id: UUID
    let key: String
    let title: String
    let because: String
    let confidence: String
    let action: Action
    let status: String
}

struct LearningState: Sendable {
    let insights: [Insight]
    let recommendations: [Recommendation]
}

// MARK: - Calls

enum AnalyticsError: LocalizedError {
    case noBrand
    case empty

    var errorDescription: String? {
        switch self {
        case .noBrand: "Choose an app first."
        case .empty:   "Nothing came back."
        }
    }
}

extension AppSession {
    private static let analyticsDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct ReportParams: Encodable, Sendable {
        let p_brand: String
        let p_from: String
        let p_to: String
        let p_platform: String?
        let p_format: String?
        let p_pillar: String?
        let p_plan: String?
    }

    func analyticsReport(_ query: AnalyticsQuery) async throws -> AnalyticsReport {
        guard let brand else { throw AnalyticsError.noBrand }
        let response = try await client
            .rpc("analytics_report", params: ReportParams(
                p_brand: brand.id.uuidString,
                p_from: AnalyticsQuery.dayString(query.from),
                p_to: AnalyticsQuery.dayString(query.to),
                p_platform: query.platform,
                p_format: query.format,
                p_pillar: query.pillarId?.uuidString,
                p_plan: query.planId?.uuidString
            ))
            .execute()
        return try Self.analyticsDecoder.decode(AnalyticsReport.self, from: response.data)
    }

    func postsLibrary() async throws -> PostsLibrary {
        guard let brand else { throw AnalyticsError.noBrand }
        let response = try await client
            .rpc("library_videos", params: ["p_brand": brand.id.uuidString])
            .execute()
        return try Self.analyticsDecoder.decode(PostsLibrary.self, from: response.data)
    }

    func postAnalytics(videoId: String) async throws -> PostAnalytics {
        guard let brand else { throw AnalyticsError.noBrand }
        struct Params: Encodable, Sendable {
            let p_brand: String
            let p_video: String
        }
        let response = try await client
            .rpc("post_analytics", params: Params(p_brand: brand.id.uuidString, p_video: videoId))
            .execute()
        return try Self.analyticsDecoder.decode(PostAnalytics.self, from: response.data)
    }

    func autopilotReport(from: Date, to: Date) async throws -> AutopilotReport {
        guard let brand else { throw AnalyticsError.noBrand }
        struct Params: Encodable, Sendable {
            let p_brand: String
            let p_from: String
            let p_to: String
        }
        let response = try await client
            .rpc("autopilot_report", params: Params(
                p_brand: brand.id.uuidString,
                p_from: AnalyticsQuery.dayString(from),
                p_to: AnalyticsQuery.dayString(to)
            ))
            .execute()
        return try Self.analyticsDecoder.decode(AutopilotReport.self, from: response.data)
    }

    func learning() async throws -> LearningState {
        guard let brand else { throw AnalyticsError.noBrand }
        let insightRows = try await client
            .from("insights")
            .select("id, key, statement, metric, lift, sample_size, confidence, evidence, period_start, period_end, platforms, content_types")
            .eq("brand_id", value: brand.id.uuidString)
            .eq("status", value: "active")
            .order("sample_size", ascending: false)
            .execute()
        let recommendationRows = try await client
            .from("recommendations")
            .select("id, key, title, because, confidence, action, status")
            .eq("brand_id", value: brand.id.uuidString)
            .in("status", values: ["open", "applied", "planned"])
            .order("updated_at", ascending: false)
            .execute()
        return LearningState(
            insights: try Self.analyticsDecoder.decode([Insight].self, from: insightRows.data),
            recommendations: try Self.analyticsDecoder.decode([Recommendation].self, from: recommendationRows.data)
        )
    }

    /// Applies, plans, ignores or reopens a recommendation. Returns the brief
    /// for "plan", so the plan writer opens already knowing what to do.
    func act(on recommendation: Recommendation, _ action: String) async -> (status: String, brief: String?)? {
        struct Params: Encodable, Sendable {
            let p_id: String
            let p_action: String
        }
        struct Outcome: Decodable {
            let status: String
            let brief: String?
        }
        do {
            let response = try await client
                .rpc("act_on_recommendation", params: Params(p_id: recommendation.id.uuidString, p_action: action))
                .execute()
            let outcome = try Self.analyticsDecoder.decode(Outcome.self, from: response.data)
            return (outcome.status, outcome.brief)
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }

    /// A real file of the report on screen, made on the server and kept like
    /// every other export. Nil, with the reason in `lastError`, when it failed.
    func exportAnalytics(_ query: AnalyticsQuery, as file: String) async -> URL? {
        guard let brand else { return nil }
        struct Request: Encodable, Sendable {
            let brand_id: String
            let from: String
            let to: String
            let platform: String?
            let format: String?
            let pillar: String?
            let plan: String?
            let file: String
        }
        struct Response: Decodable {
            let artifact_id: UUID
        }
        do {
            let response: Response = try await client.functions.invoke(
                "analytics-export",
                options: FunctionInvokeOptions(body: Request(
                    brand_id: brand.id.uuidString,
                    from: AnalyticsQuery.dayString(query.from),
                    to: AnalyticsQuery.dayString(query.to),
                    platform: query.platform,
                    format: query.format,
                    pillar: query.pillarId?.uuidString,
                    plan: query.planId?.uuidString,
                    file: file
                ))
            )
            guard let made = await artifact(response.artifact_id) else {
                lastError = "The file was made but could not be opened."
                return nil
            }
            return await localCopy(of: made)
        } catch {
            lastError = readableMessage(error)
            return nil
        }
    }
}
