import XCTest
import ImageIO
@testable import ContentApp

/// The editor's timeline arithmetic. Everything the preview and the export
/// render comes from these numbers, so a wrong one is a wrong video.
final class StudioProjectTests: XCTestCase {
    private func clip(_ seconds: Double) -> StudioClip {
        .video(URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"), duration: seconds)
    }

    func testDurationAddsTrimmedClipsAtTheirSpeed() {
        var project = StudioProject(clips: [clip(10), clip(4)])
        project.setSpeed(project.clips[0].id, 2)
        XCTAssertEqual(project.duration, 5 + 4, accuracy: 0.0001)
        XCTAssertEqual(project.start(of: 1), 5, accuracy: 0.0001)
    }

    func testClipAtTimeFindsTheRightClipAndOffset() {
        let project = StudioProject(clips: [clip(3), clip(5)])
        let hit = project.clip(at: 4)
        XCTAssertEqual(hit?.index, 1)
        XCTAssertEqual(hit?.offset ?? -1, 1, accuracy: 0.0001)
        // Past the end lands on the last clip, not nowhere.
        XCTAssertEqual(project.clip(at: 99)?.index, 1)
    }

    func testSplitCutsInSourceTimeAtTheClipsSpeed() {
        var project = StudioProject(clips: [clip(10)])
        project.setSpeed(project.clips[0].id, 2)   // 5 s on the timeline
        XCTAssertTrue(project.split(at: 2))         // 2 s in = 4 s of source
        XCTAssertEqual(project.clips.count, 2)
        XCTAssertEqual(project.clips[0].trimEnd, 4, accuracy: 0.0001)
        XCTAssertEqual(project.clips[1].trimStart, 4, accuracy: 0.0001)
        XCTAssertNotEqual(project.clips[0].id, project.clips[1].id)
        XCTAssertEqual(project.duration, 5, accuracy: 0.0001)
    }

    func testSplitRefusesSlivers() {
        var project = StudioProject(clips: [clip(3)])
        XCTAssertFalse(project.split(at: 0.1))
        XCTAssertFalse(project.split(at: 2.95))
        XCTAssertEqual(project.clips.count, 1)
    }

    func testTrimStaysInsideTheSourceAndAboveTheShortest() {
        var project = StudioProject(clips: [clip(6)])
        let id = project.clips[0].id
        project.trim(id, start: -2, end: 99)
        XCTAssertEqual(project.clips[0].trimStart, 0)
        XCTAssertEqual(project.clips[0].trimEnd, 6)
        project.trim(id, start: 5, end: 5)
        XCTAssertGreaterThanOrEqual(project.clips[0].trimmedLength, StudioProject.shortest - 0.0001)
        XCTAssertLessThanOrEqual(project.clips[0].trimEnd, 6)
    }

    func testMoveAndRemoveKeepAtLeastOneClip() {
        var project = StudioProject(clips: [clip(1), clip(2)])
        let first = project.clips[0].id
        project.move(first, by: 1)
        XCTAssertEqual(project.clips[1].id, first)
        project.move(first, by: 1)   // already last: nothing happens
        XCTAssertEqual(project.clips[1].id, first)
        project.remove(project.clips[0].id)
        project.remove(project.clips[0].id)
        XCTAssertEqual(project.clips.count, 1)
    }

    func testPhotosShowThreeSecondsAndCanStretchToTen() {
        let photo = StudioClip.photo(URL(fileURLWithPath: "/tmp/p.jpg"))
        XCTAssertEqual(photo.duration, 3)
        XCTAssertEqual(photo.sourceDuration, 10)
    }

    func testUndoAndRedo() {
        var history = EditHistory<StudioProject>()
        var project = StudioProject(clips: [clip(4)])
        let before = project
        history.record(project)
        project.setSpeed(project.clips[0].id, 2)
        let after = project
        project = history.undo(project) ?? project
        XCTAssertEqual(project, before)
        project = history.redo(project) ?? project
        XCTAssertEqual(project, after)
        XCTAssertFalse(history.canRedo)
    }

    func testTextVisibility() {
        let whole = StudioText(text: "hi")
        XCTAssertTrue(whole.isVisible(at: 100))
        var timed = StudioText(text: "hi")
        timed.start = 1
        timed.end = 2
        XCTAssertFalse(timed.isVisible(at: 0.5))
        XCTAssertTrue(timed.isVisible(at: 1.5))
        XCTAssertFalse(timed.isVisible(at: 2))
    }

    func testCompositorReadsTrackTransformsAsOrientation() {
        XCTAssertEqual(StudioCompositor.orientation(of: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)), .right)
        XCTAssertEqual(StudioCompositor.orientation(of: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 0)), .left)
        XCTAssertEqual(StudioCompositor.orientation(of: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 0, ty: 0)), .down)
        XCTAssertEqual(StudioCompositor.orientation(of: .identity), .up)
    }
}
