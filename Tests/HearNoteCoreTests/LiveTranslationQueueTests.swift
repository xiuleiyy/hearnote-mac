import Foundation
import XCTest
@testable import HearNoteCore

final class LiveTranslationQueueTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    func testTimestampUpdatesDoNotRestartTextStabilityWait() {
        var queue = LiveTranslationQueue()
        var segment = TranscriptSegment(start: 0, end: 1, text: "预算三百元。")
        queue.update(segment, isFinal: false, now: origin)
        segment.end = 1.1
        queue.update(segment, isFinal: false, now: origin.addingTimeInterval(1))

        XCTAssertNil(queue.next(now: origin.addingTimeInterval(1.1)))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(1.3)), segment)
    }

    func testActualTextRevisionRestartsStabilityWait() {
        var queue = LiveTranslationQueue()
        var segment = TranscriptSegment(text: "预算三千元。")
        queue.update(segment, isFinal: false, now: origin)
        segment.text = "预算三百元。"
        queue.update(segment, isFinal: false, now: origin.addingTimeInterval(1))

        XCTAssertNil(queue.next(now: origin.addingTimeInterval(1.3)))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(2.3)), segment)
    }

    func testFinalAndFlushSubmitWithoutWaitingForStability() {
        let segment = TranscriptSegment(text: "尚未决定发布日期。")
        var queue = LiveTranslationQueue()
        queue.update(segment, isFinal: false, now: origin)
        XCTAssertNil(queue.next(now: origin))
        XCTAssertEqual(queue.next(now: origin, flush: true), segment)

        queue.update(segment, isFinal: true, now: origin)
        XCTAssertEqual(queue.next(now: origin), segment)
    }

    func testSentenceDraftWaitsForFinalEvenWhenTextHasNotChanged() {
        var queue = LiveTranslationQueue()
        var draft = TranscriptSegment(start: 0, end: 2, text: "Please keep the")
        queue.update(draft, isFinal: false, now: origin, requiresFinal: true)
        XCTAssertTrue(queue.isWaitingForSentence(for: draft))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(30)))

        draft.text = "Please keep the response time below 200 milliseconds."
        draft.end = 6
        queue.update(draft, isFinal: true, now: origin.addingTimeInterval(6), requiresFinal: true)
        XCTAssertFalse(queue.isWaitingForSentence(for: draft))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(6)), draft)
        XCTAssertTrue(queue.commit("请将响应时间保持在 200 毫秒以下。", for: draft))
    }

    func testUnfinishedSentenceCanFlushAndDoesNotBlockAnotherAudioSource() {
        var queue = LiveTranslationQueue()
        let draft = TranscriptSegment(start: 0, end: 2, text: "The remaining", source: "麦克风")
        let complete = TranscriptSegment(start: 3, end: 4, text: "Please continue.", source: "会议声音")
        queue.update(draft, isFinal: false, now: origin, requiresFinal: true)
        queue.update(complete, isFinal: true, now: origin, requiresFinal: true)
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(30)), complete)
        XCTAssertTrue(queue.commit("请继续。", for: complete))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(30)))
        XCTAssertEqual(queue.next(now: origin, flush: true), draft)
    }

    func testRevisedCompletedSentenceWithdrawsOldTranslationUntilNewFinal() {
        var queue = LiveTranslationQueue()
        var segment = TranscriptSegment(text: "Deploy tomorrow.")
        queue.update(segment, isFinal: true, now: origin, requiresFinal: true)
        XCTAssertTrue(queue.commit("明天部署。", for: segment))
        segment.text = "Do not deploy"
        queue.update(segment, isFinal: false, now: origin, requiresFinal: true)
        XCTAssertNil(queue.translation(for: segment))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(30)))
        segment.text = "Do not deploy tomorrow."
        queue.update(segment, isFinal: true, now: origin, requiresFinal: true)
        XCTAssertEqual(queue.next(now: origin), segment)
    }

    func testResumingTranslationDoesNotTranslateAnUnchangedPausedSentence() {
        var queue = LiveTranslationQueue()
        let segment = TranscriptSegment(text: "A complete sentence.")
        queue.suspend()
        queue.update(segment, isFinal: false, now: origin, requiresFinal: true)
        queue.resume()
        queue.update(segment, isFinal: true, now: origin, requiresFinal: true)
        XCTAssertFalse(queue.hasPending)
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(30), flush: true))
    }

    func testRevisedTextInvalidatesVisibleTranslationAndRejectsOutdatedResult() {
        var queue = LiveTranslationQueue()
        let original = TranscriptSegment(text: "明天发布。")
        queue.update(original, isFinal: true, now: origin)
        XCTAssertTrue(queue.commit("Release tomorrow.", for: original))
        XCTAssertEqual(queue.translation(for: original), "Release tomorrow.")

        var corrected = original
        corrected.text = "明天不发布。"
        queue.update(corrected, isFinal: false, now: origin.addingTimeInterval(1))
        XCTAssertNil(queue.translations[original.id])
        XCTAssertNil(queue.translation(for: corrected))
        XCTAssertFalse(queue.commit("Release tomorrow.", for: original))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(2.3)), corrected)

        XCTAssertTrue(queue.commit("Do not release tomorrow.", for: corrected))
        XCTAssertEqual(queue.translation(for: corrected), "Do not release tomorrow.")
        XCTAssertNil(queue.translation(for: original))
        XCTAssertFalse(queue.hasPending)
    }

    func testTextRestoredAfterRevisionRemainsPending() {
        var queue = LiveTranslationQueue()
        let original = TranscriptSegment(text: "三百元。")
        queue.update(original, isFinal: true, now: origin)
        XCTAssertTrue(queue.commit("300 yuan.", for: original))

        var changed = original
        changed.text = "三千元。"
        queue.update(changed, isFinal: false, now: origin.addingTimeInterval(1))
        queue.update(original, isFinal: false, now: origin.addingTimeInterval(2))

        XCTAssertTrue(queue.hasPending)
        XCTAssertNil(queue.translations[original.id])
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(2.3)))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(3.3)), original)
    }

    func testMatureSegmentsFromBothAudioSourcesUseDeterministicChronologicalOrder() {
        let earlier = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            start: 1, end: 2, text: "会议声音。", source: "会议声音"
        )
        let sameTime = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            start: 1, end: 2, text: "麦克风声音。", source: "麦克风"
        )
        let immature = TranscriptSegment(start: 0, end: 1, text: "还在更正。")
        var queue = LiveTranslationQueue()
        queue.update(sameTime, isFinal: true, now: origin)
        queue.update(immature, isFinal: false, now: origin)
        queue.update(earlier, isFinal: true, now: origin)

        XCTAssertEqual(queue.next(now: origin), earlier)
        XCTAssertTrue(queue.commit("Meeting audio.", for: earlier))
        XCTAssertEqual(queue.next(now: origin), sameTime)
        XCTAssertTrue(queue.commit("Microphone audio.", for: sameTime))
        XCTAssertNil(queue.next(now: origin))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(1.3)), immature)
    }

    func testClearingPendingKeepsCommittedTranslationsAndRejectsInFlightResults() {
        var queue = LiveTranslationQueue()
        let finished = TranscriptSegment(text: "已完成。")
        let pending = TranscriptSegment(text: "还在翻译。")
        queue.update(finished, isFinal: true, now: origin)
        XCTAssertTrue(queue.commit("Completed.", for: finished))
        queue.update(pending, isFinal: true, now: origin)
        queue.clearPending()

        XCTAssertFalse(queue.hasPending)
        XCTAssertEqual(queue.translation(for: finished), "Completed.")
        XCTAssertFalse(queue.commit("Still translating.", for: pending))
        XCTAssertNil(queue.translations[pending.id])
    }

    func testRemovingChunksClearsTranslationsAndRejectsInFlightResultsWithoutAffectingOthers() {
        var queue = LiveTranslationQueue()
        let removedCompleted = TranscriptSegment(text: "识别撤回的片段。")
        let removedPending = TranscriptSegment(text: "请求仍在执行的片段。")
        let retainedCompleted = TranscriptSegment(text: "保留的已完成片段。")
        let retainedPending = TranscriptSegment(text: "保留的待翻译片段。")
        queue.update(removedCompleted, isFinal: true, now: origin)
        queue.update(retainedCompleted, isFinal: true, now: origin)
        XCTAssertTrue(queue.commit("Retracted chunk.", for: removedCompleted))
        XCTAssertTrue(queue.commit("Retained completed chunk.", for: retainedCompleted))
        queue.update(removedPending, isFinal: true, now: origin)
        queue.update(retainedPending, isFinal: true, now: origin)

        queue.remove(id: removedCompleted.id)
        queue.remove(id: removedPending.id)

        XCTAssertNil(queue.translation(for: removedCompleted))
        XCTAssertNil(queue.translations[removedCompleted.id])
        XCTAssertFalse(queue.commit("Late result.", for: removedPending))
        XCTAssertNil(queue.translations[removedPending.id])
        XCTAssertEqual(queue.translation(for: retainedCompleted), "Retained completed chunk.")
        XCTAssertEqual(queue.next(now: origin), retainedPending)
        XCTAssertTrue(queue.hasPending)
    }

    func testResumeSkipsUnchangedPausedChunksButAllowsRevisionsAndNewChunks() {
        var queue = LiveTranslationQueue()
        var beforePause = TranscriptSegment(start: 0, end: 1, text: "关闭前还在翻译。")
        queue.update(beforePause, isFinal: true, now: origin)
        queue.suspend()
        XCTAssertTrue(queue.isSuspended)
        XCTAssertFalse(queue.commit("Late result.", for: beforePause))

        var duringPause = TranscriptSegment(start: 2, end: 3, text: "关闭期间出现的新片段。")
        queue.update(duringPause, isFinal: false, now: origin.addingTimeInterval(1))
        XCTAssertFalse(queue.hasPending)
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(5), flush: true))
        queue.resume()

        beforePause.end = 1.1
        queue.update(beforePause, isFinal: true, now: origin.addingTimeInterval(6))
        duringPause.end = 3.1
        queue.update(duringPause, isFinal: false, now: origin.addingTimeInterval(6))
        queue.update(duringPause, isFinal: true, now: origin.addingTimeInterval(7))
        XCTAssertFalse(queue.hasPending)
        XCTAssertFalse(queue.isSuspended)

        duringPause.text = "恢复之后文字确实被更正。"
        queue.update(duringPause, isFinal: true, now: origin.addingTimeInterval(8))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(8)), duringPause)
        XCTAssertTrue(queue.commit("The text was corrected after resuming.", for: duringPause))

        let newChunk = TranscriptSegment(start: 8, end: 9, text: "恢复之后的新片段。")
        queue.update(newChunk, isFinal: true, now: origin.addingTimeInterval(9))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(9)), newChunk)
    }

    func testSuspendedRevisionImmediatelyInvalidatesCompletedTranslation() {
        var queue = LiveTranslationQueue()
        var segment = TranscriptSegment(text: "明天发布。")
        queue.update(segment, isFinal: true, now: origin)
        XCTAssertTrue(queue.commit("Release tomorrow.", for: segment))
        queue.suspend()
        XCTAssertEqual(queue.translation(for: segment), "Release tomorrow.")

        segment.text = "明天不发布。"
        queue.update(segment, isFinal: false, now: origin.addingTimeInterval(1))
        XCTAssertNil(queue.translations[segment.id])
        XCTAssertNil(queue.translation(for: segment))
        XCTAssertFalse(queue.hasPending)

        queue.resume()
        queue.update(segment, isFinal: true, now: origin.addingTimeInterval(2))
        XCTAssertFalse(queue.hasPending)
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(2)))
    }

    func testRemovingChunkAndStartingNewQueueClearPausedSnapshot() {
        var queue = LiveTranslationQueue()
        let segment = TranscriptSegment(text: "暂停期间的片段。")
        queue.suspend()
        queue.update(segment, isFinal: true, now: origin)
        queue.resume()
        queue.remove(id: segment.id)
        queue.update(segment, isFinal: true, now: origin.addingTimeInterval(1))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(1)), segment)

        queue.suspend()
        queue = LiveTranslationQueue()
        queue.update(segment, isFinal: true, now: origin.addingTimeInterval(2))
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(2)), segment)
    }
}
