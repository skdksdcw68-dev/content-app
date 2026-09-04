import Foundation

/// One short-form video, from the idea the autopilot had to the post it made.
///
/// Everything on here except `approvedAt` is written by the autopilot. The
/// person's only input is approving, editing or skipping -- which is the whole
/// product: you read what it decided, you do not assemble it.
struct ContentPost: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var hook: String
    var script: String
    var caption: String
    var hashtags: [String]
    var platform: Platform
    var status: PostStatus
    var pillarID: UUID?

    /// Why the autopilot chose this, in one line, in its own words. Shown on
    /// the row and expanded in the detail view. Without it the app is a queue
    /// of things that appeared for no reason.
    var rationale: String

    /// When it is set to go out. Nil only while `status == .planned`.
    var scheduledFor: Date?
    var postedAt: Date?
    /// Set when a person approved it. Nil means the autopilot has not been
    /// cleared to publish -- relevant only when `requiresApproval` is on.
    var approvedAt: Date?
    var failureReason: String?

    /// Populated after `status == .posted`.
    var views: Int?
    var likes: Int?

    var createdAt: Date

    init(
        id: UUID = UUID(),
        hook: String,
        script: String = "",
        caption: String = "",
        hashtags: [String] = [],
        platform: Platform,
        status: PostStatus,
        pillarID: UUID? = nil,
        rationale: String,
        scheduledFor: Date? = nil,
        postedAt: Date? = nil,
        approvedAt: Date? = nil,
        failureReason: String? = nil,
        views: Int? = nil,
        likes: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.hook = hook
        self.script = script
        self.caption = caption
        self.hashtags = hashtags
        self.platform = platform
        self.status = status
        self.pillarID = pillarID
        self.rationale = rationale
        self.scheduledFor = scheduledFor
        self.postedAt = postedAt
        self.approvedAt = approvedAt
        self.failureReason = failureReason
        self.views = views
        self.likes = likes
        self.createdAt = createdAt
    }

    /// The date this post sorts by: when it went out, or when it is due.
    /// Falls back to creation so a freshly planned post is never undated.
    var effectiveDate: Date {
        postedAt ?? scheduledFor ?? createdAt
    }

    /// True when the autopilot is holding this back waiting on a person.
    var isAwaitingApproval: Bool {
        status == .scheduled && approvedAt == nil
    }

    /// Rough spoken length of the script, at 150 words per minute. Used to
    /// keep a script inside `Platform.maxDuration` before anything is rendered.
    var estimatedDuration: TimeInterval {
        let words = script.split { $0 == " " || $0.isNewline }.count
        return Double(words) / 150.0 * 60.0
    }

    var fitsPlatform: Bool {
        estimatedDuration <= platform.maxDuration
    }
}
