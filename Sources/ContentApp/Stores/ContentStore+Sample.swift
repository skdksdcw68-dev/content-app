import Foundation

/// Pre-planned stand-in for a first sync with the planner.
///
/// Every rationale here is written the way the real model is prompted to write
/// one: a specific reason tied to a pillar or a result, never "this will do
/// well". If the sample data is vague, the real thing will be too -- this file
/// is the spec for that field.
extension ContentStore {
    static var samplePillars: [ContentPillar] {
        [
            ContentPillar(
                name: "Behind the build",
                detail: "What you are making this week, shown half-finished.",
                weight: 3
            ),
            ContentPillar(
                name: "One hard-won lesson",
                detail: "A thing that cost you time, and what you do now instead.",
                weight: 2
            ),
            ContentPillar(
                name: "Answer a real question",
                detail: "Something someone actually asked in the comments or DMs.",
                weight: 2
            ),
            ContentPillar(
                name: "Trend, but on your terms",
                detail: "A current format, applied to your subject, never for its own sake.",
                weight: 1,
                isEnabled: false
            )
        ]
    }

    static func samplePosts(pillars: [ContentPillar]) -> [ContentPost] {
        let build = pillars.first { $0.name == "Behind the build" }?.id
        let lesson = pillars.first { $0.name == "One hard-won lesson" }?.id
        let question = pillars.first { $0.name == "Answer a real question" }?.id

        let now = Date()
        func hours(_ n: Double) -> Date { now.addingTimeInterval(n * 3600) }

        return [
            ContentPost(
                hook: "I shipped an iOS app without owning a Mac.",
                script: """
                    Everyone tells you that you need a Mac to build for iPhone. \
                    You do not. You need a Mac for about eleven minutes, and you \
                    can rent that. Here is the whole pipeline. I write Swift on a \
                    Windows laptop. I push to GitHub. A macOS runner picks it up, \
                    generates the Xcode project from a config file, compiles it, \
                    signs it, and hands it to TestFlight. Ten minutes later it is \
                    on my phone. The project file is never opened by a human. That \
                    is the trick nobody mentions.
                    """,
                caption: "The Mac requirement is a rental, not a purchase.",
                hashtags: ["#ios", "#swift", "#buildinpublic"],
                platform: .tiktok,
                status: .scheduled,
                pillarID: build,
                rationale: "Your last three posts about the Windows setup outperformed everything else by roughly 4x. This is the same thread, told from the start for people who missed it.",
                scheduledFor: hours(5)
            ),
            ContentPost(
                hook: "This one setting cost me a day of debugging.",
                script: """
                    My app kept dying about a minute after launch. No crash log \
                    that meant anything. It turned out to be a data race in a \
                    class two screens away, quietly corrupting the heap. The \
                    compiler could have told me on day one. There is a flag, \
                    strict concurrency checking, and it was off. I turned it on \
                    and got forty warnings. Every one of them was a place I had \
                    not thought about yet. Turn it on before you need it.
                    """,
                caption: "Forty warnings beats one heisenbug.",
                hashtags: ["#swift", "#debugging", "#devtips"],
                platform: .tiktok,
                status: .scheduled,
                pillarID: lesson,
                rationale: "Pillar balance: three build posts are queued and no lesson posts. This one is drawn from the concurrency bug in your commit history last week.",
                scheduledFor: hours(29),
                approvedAt: now
            ),
            ContentPost(
                hook: "\"How do you sign builds with no Mac?\"",
                script: """
                    Asked four times this week, so here is the answer properly. \
                    You never touch Xcode. The certificate and the provisioning \
                    profile are made once, directly against Apple's API, and \
                    stored as encrypted secrets. The runner decodes them into a \
                    throwaway keychain it creates itself, with a password it \
                    knows. That last part matters. Use the default keychain and \
                    codesign puts up a dialog box, on a machine with no screen, \
                    and waits there until the job times out.
                    """,
                caption: "The keychain detail is the one that gets everyone.",
                hashtags: ["#ios", "#cicd", "#fastlane"],
                platform: .tiktok,
                status: .scripted,
                pillarID: question,
                rationale: "Four separate comments asked this on the pipeline video. Answering a repeated question directly tends to convert commenters into followers.",
                scheduledFor: hours(53)
            ),
            ContentPost(
                hook: "The build uploaded fine. It never appeared.",
                platform: .tiktok,
                status: .planned,
                pillarID: lesson,
                rationale: "Continues the CI thread while it is working. Not written yet -- waiting to see how the signing post performs before committing a slot to it."
            ),
            ContentPost(
                hook: "Three weeks of building, in sixty seconds.",
                script: """
                    Week one, it was a text file. Week two, it had screens but \
                    no data. Week three, it is on my phone and my friends are \
                    using it. Nothing here was hard. All of it was just done in \
                    order, on days I did not feel like it.
                    """,
                caption: "In order, on the days you don't feel like it.",
                hashtags: ["#buildinpublic", "#indiedev"],
                platform: .tiktok,
                status: .posted,
                pillarID: build,
                rationale: "Recap format, planned for the end of a build streak. Montages consistently pull your best completion rate.",
                scheduledFor: hours(-20),
                postedAt: hours(-20),
                approvedAt: hours(-22),
                views: 18_400,
                likes: 2_130
            ),
            ContentPost(
                hook: "Why I stopped using a CI service.",
                platform: .tiktok,
                status: .failed,
                pillarID: lesson,
                rationale: "Planned as a follow-up to the pipeline post.",
                scheduledFor: hours(-4),
                failureReason: "Render failed: the generated voiceover ran to 3m 12s, over TikTok's 3m limit. Shorten the script and it will retry."
            )
        ]
    }
}
