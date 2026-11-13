import Foundation
import XCTest
@testable import HearNoteCore

final class AppleSpeechFinalizationTests: XCTestCase {
    func testLaterFinalResultCannotSealAnEarlierVolatileNegation() {
        var mapper = AppleSpeechResultMapper()
        var visible: [UUID: TranscriptSegment] = [:]
        let initial = mapper.receive(
            text: "We have.", start: 0, end: 0.256, isFinal: false,
            resultsFinalizationTime: 0, source: "录音"
        )
        apply(initial, to: &visible)
        let firstID = initial[0].segment.id
        apply(mapper.receive(
            text: "Keep the API timeout at 300 milliseconds.", start: 2.17, end: 5.59,
            isFinal: true, resultsFinalizationTime: 0, source: "录音"
        ), to: &visible)
        let revision = mapper.receive(
            text: "We have not agreed on the launch date.", start: 0, end: 2.17,
            isFinal: true, resultsFinalizationTime: 2.17, source: "录音"
        )
        apply(revision, to: &visible)
        XCTAssertEqual(visible[firstID]?.text, "We have not agreed on the launch date.")
        XCTAssertEqual(visible.values.sorted { $0.start < $1.start }.map(\.text), [
            "We have not agreed on the launch date.",
            "Keep the API timeout at 300 milliseconds."
        ])
        XCTAssertTrue(revision.contains { $0.segment.id == firstID && $0.isFinal })
        XCTAssertFalse(mapper.hasPendingText)
    }

    func testAnIndividualFinalRangeCannotBeRewrittenOrRetractedBeforeWatermarkAdvances() {
        var mapper = AppleSpeechResultMapper()
        let final = mapper.receive(
            text: "The budget is 300 yuan, not 3,000.", start: 5, end: 8, isFinal: true,
            resultsFinalizationTime: 0, source: "会议声音"
        )[0]
        XCTAssertTrue(final.isFinal)
        for text in ["The budget is 3,000 yuan.", "", "late duplicate"] {
            XCTAssertTrue(mapper.receive(
                text: text, start: 5, end: 8, isFinal: false,
                resultsFinalizationTime: 0, source: "会议声音"
            ).isEmpty)
        }
        let earlier = mapper.receive(
            text: "We have not approved the budget.", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音"
        )
        XCTAssertEqual(earlier.map(\.segment.text), ["We have not approved the budget."])
        XCTAssertFalse(earlier[0].isFinal)
        XCTAssertEqual(mapper.unmappableRevisionCount, 0)
    }

    func testTimedRevisionCrossingModuleWatermarkCanStillCorrectUnsealedTail() {
        var mapper = AppleSpeechResultMapper()
        var visible: [UUID: TranscriptSegment] = [:]
        apply(mapper.receive(
            text: "First. We can ship.", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 0, source: nil,
            timedText: [.init(text: "First. ", start: 0, end: 2),
                        .init(text: "We can ship.", start: 2, end: 4)]
        ), to: &visible)
        apply(mapper.receive(
            text: "", start: 8, end: 8, isFinal: false,
            resultsFinalizationTime: 2, source: nil
        ), to: &visible)
        let immutableFirst = visible.values.first { $0.text == "First." }!
        apply(mapper.receive(
            text: "Old prefix. We cannot ship yet.", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 2, source: nil,
            timedText: [.init(text: "Old prefix. ", start: 0, end: 2),
                        .init(text: "We cannot ship yet.", start: 2, end: 4)]
        ), to: &visible)
        XCTAssertEqual(visible[immutableFirst.id], immutableFirst)
        XCTAssertEqual(visible.values.sorted { $0.start < $1.start }.map(\.text),
                       ["First.", "We cannot ship yet."])
        XCTAssertEqual(mapper.unmappableRevisionCount, 0)
    }

    func testTimedWideRevisionOnlyChangesTheRangesBesideAnIndividualFinalResult() {
        var mapper = AppleSpeechResultMapper()
        var visible: [UUID: TranscriptSegment] = [:]
        apply(mapper.receive(
            text: "earlier", start: 0, end: 2, isFinal: false,
            resultsFinalizationTime: 0, source: nil
        ), to: &visible)
        let immutable = mapper.receive(
            text: "Not approved.", start: 2, end: 4, isFinal: true,
            resultsFinalizationTime: 0, source: nil
        )[0]
        apply([immutable], to: &visible)
        apply(mapper.receive(
            text: "later", start: 4, end: 6, isFinal: false,
            resultsFinalizationTime: 0, source: nil
        ), to: &visible)
        apply(mapper.receive(
            text: "Earlier correction. Approved. Later correction.", start: 0, end: 6,
            isFinal: false, resultsFinalizationTime: 0, source: nil,
            timedText: [.init(text: "Earlier correction. ", start: 0, end: 2),
                        .init(text: "Approved. ", start: 2, end: 4),
                        .init(text: "Later correction.", start: 4, end: 6)]
        ), to: &visible)
        XCTAssertEqual(visible[immutable.segment.id], immutable.segment)
        XCTAssertEqual(visible.values.sorted { $0.start < $1.start }.map(\.text),
                       ["Earlier correction.", "Not approved.", "Later correction."])
        XCTAssertEqual(mapper.unmappableRevisionCount, 0)
    }

    func testUnsplitCoarseRevisionIsCountedWithoutGuessingOrRewritingFinalText() {
        var mapper = AppleSpeechResultMapper()
        _ = mapper.receive(
            text: "Not approved.", start: 0, end: 2, isFinal: true,
            resultsFinalizationTime: 2, source: nil
        )
        let tail = mapper.receive(
            text: "Budget is 300.", start: 2, end: 4, isFinal: false,
            resultsFinalizationTime: 2, source: nil
        )[0]
        XCTAssertTrue(mapper.receive(
            text: "Approved. Budget is 3000.", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 2, source: nil,
            timedText: [.init(text: "Approved. Budget is 3000.", start: 0, end: 4)]
        ).isEmpty)
        XCTAssertEqual(mapper.unmappableRevisionCount, 1)
        XCTAssertEqual(mapper.finishSuccessfully().map(\.segment), [tail.segment])
    }

    func testCrossingRetractionDeletesOnlyPendingTailAndCannotDeleteFinalPrefix() {
        var mapper = AppleSpeechResultMapper()
        var visible: [UUID: TranscriptSegment] = [:]
        let final = mapper.receive(
            text: "We have not agreed.", start: 0, end: 2, isFinal: true,
            resultsFinalizationTime: 2, source: nil
        )[0]
        apply([final], to: &visible)
        apply(mapper.receive(
            text: "temporary tail", start: 2, end: 4, isFinal: false,
            resultsFinalizationTime: 2, source: nil
        ), to: &visible)
        apply(mapper.receive(
            text: "", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 2, source: nil
        ), to: &visible)
        XCTAssertEqual(Array(visible.values), [final.segment])
        XCTAssertFalse(mapper.hasPendingText)
        XCTAssertEqual(mapper.unmappableRevisionCount, 0)
    }

    func testSuccessfulFinishDrainsPendingOnceAndNewMapperHasIndependentState() {
        var mapper = AppleSpeechResultMapper()
        let pending = mapper.receive(
            text: "Not ready yet.", start: 0, end: 2, isFinal: false,
            resultsFinalizationTime: 0, source: "麦克风"
        )[0]
        let finished = mapper.finishSuccessfully()
        XCTAssertEqual(finished.map(\.segment), [pending.segment])
        XCTAssertTrue(finished.allSatisfy(\.isFinal))
        XCTAssertFalse(mapper.hasPendingText)
        XCTAssertTrue(mapper.finishSuccessfully().isEmpty)
        XCTAssertTrue(mapper.receive(
            text: "Late callback.", start: 10, end: 12, isFinal: false,
            resultsFinalizationTime: 0, source: "麦克风"
        ).isEmpty)

        var next = AppleSpeechResultMapper()
        XCTAssertEqual(next.unmappableRevisionCount, 0)
        let new = next.receive(
            text: "New meeting.", start: 0, end: 2, isFinal: false,
            resultsFinalizationTime: 0, source: "麦克风"
        )
        XCTAssertEqual(new.map(\.segment.text), ["New meeting."])
        XCTAssertNotEqual(new[0].segment.id, pending.segment.id)
    }

    private func apply(_ updates: [AppleSpeechResultMapper.Update],
                       to visible: inout [UUID: TranscriptSegment]) {
        for update in updates {
            if update.segment.text.isEmpty { visible.removeValue(forKey: update.segment.id) }
            else { visible[update.segment.id] = update.segment }
        }
    }
}
