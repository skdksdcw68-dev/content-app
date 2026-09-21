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

    func testProgressCoversOnlyTheQuestionsAndNeverFillsEarly() {
        XCTAssertNil(OnboardingStep.welcome.progress)
        // The account screens are a choice, not a queue to be got through.
        XCTAssertNil(OnboardingStep.account.progress)
        XCTAssertNil(OnboardingStep.email(.signup).progress)
        XCTAssertNil(OnboardingStep.code(.login).progress)
        XCTAssertNil(OnboardingStep.verified(.created).progress)

        let first = try? XCTUnwrap(OnboardingStep.question(0).progress)
        let last = try? XCTUnwrap(OnboardingStep.question(OnboardingQuestion.all.count - 1).progress)
        let included = try? XCTUnwrap(OnboardingStep.included.progress)
        XCTAssertNotNil(first)
        XCTAssertLessThan(first ?? 1, last ?? 0)
        XCTAssertLessThan(last ?? 1, included ?? 0)
        // Only being in the app is 100%.
        XCTAssertLessThan(included ?? 1, 1)
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
        XCTAssertEqual(OnboardingQuestion.all.count, 6)
        XCTAssertEqual(OnboardingQuestion.all.map(\.id), ["category", "goal", "audience", "styles", "voice", "cta"])
        for question in OnboardingQuestion.all {
            XCTAssertFalse(question.options.isEmpty, "\(question.id) has no options")
            XCTAssertFalse(OnboardingPrompt.title(for: question).isEmpty)
        }
    }
}
