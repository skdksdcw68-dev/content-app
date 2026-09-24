import XCTest
@testable import ContentApp

/// First run's step machine. Every one of these is a way somebody has actually
/// been stranded: a step that cannot be restored, an old stored value from a
/// previous version, or a progress bar that reads full while there is still a
/// screen to answer.
final class OnboardingTests: XCTestCase {
    private var everyStep: [OnboardingStep] {
        [.welcome, .question(0), .question(OnboardingQuestion.all.count - 1),
         .building, .included, .account,
         .email(.signup), .email(.login), .code(.signup), .code(.login),
         .verified(.created), .verified(.alreadyRegistered), .verified(.returning), .done]
    }

    func testEveryStepSurvivesBeingStored() {
        for step in everyStep {
            XCTAssertEqual(OnboardingStep(stored: step.storedValue), step, "\(step) did not come back")
        }
    }

    /// Someone mid-flow when the app updates must land somewhere sensible.
    func testRetiredStepsMapSomewhereSensible() {
        // Asked for a name before the app had been used; that screen is gone.
        XCTAssertEqual(OnboardingStep(stored: "name"), .welcome)
        // The old connect-a-generator screen.
        XCTAssertEqual(OnboardingStep(stored: "generator"), .done)
        XCTAssertNil(OnboardingStep(stored: "nonsense"))
    }

    /// The bar belongs to the questions. Everything after them is a choice,
    /// not a queue, and carries no bar.
    ///
    /// 🔴 It must never read full while a question still needs answering, so
    /// the denominator is one more than the count, and only `done` is 1.
    func testProgressCoversTheQuestionsAndNeverReadsFullEarly() {
        XCTAssertNil(OnboardingStep.welcome.progress)
        XCTAssertNil(OnboardingStep.building.progress)
        XCTAssertNil(OnboardingStep.included.progress)
        XCTAssertNil(OnboardingStep.account.progress)
        XCTAssertNil(OnboardingStep.email(.signup).progress)
        XCTAssertNil(OnboardingStep.code(.login).progress)
        XCTAssertNil(OnboardingStep.verified(.created).progress)

        let first = OnboardingStep.question(0).progress
        let last = OnboardingStep.question(OnboardingQuestion.all.count - 1).progress
        XCTAssertNotNil(first)
        XCTAssertLessThan(first ?? 1, last ?? 0)
        XCTAssertLessThan(last ?? 1, 1)
        XCTAssertEqual(OnboardingStep.done.progress, 1)
    }

    func testBackBelongsOnlyWhereSomebodyChoseToGo() {
        XCTAssertFalse(OnboardingStep.welcome.canGoBack)
        // Sent here by finishing the questions, and it moves on by itself.
        XCTAssertFalse(OnboardingStep.building.canGoBack)
        XCTAssertFalse(OnboardingStep.verified(.created).canGoBack)
        XCTAssertTrue(OnboardingStep.question(2).canGoBack)
        XCTAssertTrue(OnboardingStep.account.canGoBack)
        XCTAssertTrue(OnboardingStep.code(.signup).canGoBack)
    }

    /// The questions onboarding asks are the Brand page's own, so answering
    /// them once fills the page somebody edits later.
    func testQuestionsAreTheBrandPageQuestions() {
        XCTAssertEqual(OnboardingQuestion.all.count, 12)
        XCTAssertEqual(OnboardingQuestion.all.map(\.id), [
            "category", "goal", "audience", "platforms", "styles", "formats",
            "length", "cadence", "camera", "voice", "cta", "avoid",
        ])
        // The ids are what the plan and the questionnaire look up, so no two
        // questions may share one.
        XCTAssertEqual(Set(OnboardingQuestion.all.map(\.id)).count, OnboardingQuestion.all.count)
        for question in OnboardingQuestion.all {
            XCTAssertFalse(question.options.isEmpty, "\(question.id) has no options")
            XCTAssertFalse(OnboardingPrompt.title(for: question).isEmpty)
        }
    }

    /// Every question onboarding asks has a page written for it: its own
    /// question-shaped title, not the Brand page's noun. A question added
    /// without one would silently fall back and read like a form field.
    func testEveryOnboardingQuestionHasItsOwnPage() {
        for question in OnboardingQuestion.all {
            let title = OnboardingPrompt.title(for: question)
            XCTAssertFalse(title.isEmpty, "\(question.id) has no page title")
            XCTAssertNotEqual(title, question.title, "\(question.id) falls back to its Brand page label")
            XCTAssertFalse(question.subtitle.isEmpty, "\(question.id) has no subtitle")
        }
    }

    /// Every list of choices is even, so the two-column grid never ends on a
    /// single stranded tile (Abel, 23 Sep 2026: "make sure the onboarding
    /// choices are not kind of 3, or 5, make sure they can be divided by 2").
    func testEveryQuestionHasAnEvenNumberOfChoices() {
        let everyQuestion = OnboardingQuestion.all
            + BrandQuestions.audienceGroup + BrandQuestions.contentGroup + BrandQuestions.writingGroup
        for question in everyQuestion {
            XCTAssertEqual(
                question.options.count % 2, 0,
                "\(question.id) offers \(question.options.count) choices, which leaves a gap in the grid"
            )
            // And no duplicate ids inside one question, which would make two
            // tiles toggle as one.
            XCTAssertEqual(Set(question.options.map(\.id)).count, question.options.count, "\(question.id) repeats an option id")
        }
    }

    /// Anyone who answered the original six questions before the list grew
    /// still counts as onboarded; a fresh profile does not.
    func testTheOriginalSixAnswersStillCountAsOnboarded() {
        var brand = Brand(
            id: UUID(), name: "Remi", audience: "", niche: "", timezone: "Europe/Paris",
            usesMemory: true, profile: [:]
        )
        XCTAssertFalse(brand.answeredOnboarding)
        for id in ["category", "goal", "audience", "styles", "voice", "cta"] {
            brand.profile?[id] = BrandAnswer(title: id, answers: ["x"])
        }
        XCTAssertTrue(brand.answeredOnboarding)
    }
}
