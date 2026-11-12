import Foundation
import XCTest
@testable import HearNoteCore

final class AppleSpeechPolicyTests: XCTestCase {
    @MainActor
    func testCancellationSettlesPreparationBeforeUncooperativeSystemOperationReturns() async {
        let entered = expectation(description: "system preparation entered")
        let cancelled = expectation(description: "caller cancelled promptly")
        var systemContinuation: CheckedContinuation<Void, Never>?
        var cancellationCount = 0
        let operation = AppleSpeechStartOperation { cancellationCount += 1 }
        let caller = Task { @MainActor in
            do {
                try await operation.run {
                    await withCheckedContinuation { continuation in
                        systemContinuation = continuation
                        entered.fulfill()
                    }
                }
                XCTFail("Cancelled preparation must not report success.")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        caller.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(cancellationCount, 1)
        // 系统安装继续到此处才返回；晚到成功不能再次恢复已经取消的 caller。
        systemContinuation?.resume()
        systemContinuation = nil
        await caller.value
        operation.cancel()
        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testCancellingCompletedPreparationCannotCancelReadyRecognizer() async throws {
        var cancellationCount = 0
        let operation = AppleSpeechStartOperation { cancellationCount += 1 }
        try await operation.run {}
        operation.cancel()
        XCTAssertEqual(cancellationCount, 0)
    }

    func testVolatileRevisionsAndFinalKeepOneStableSegment() {
        var mapper = AppleSpeechResultMapper()
        let first = mapper.receive(text: "We can ship", start: 10, end: 12, isFinal: false,
                                   resultsFinalizationTime: 10, source: "会议声音")
        let revised = mapper.receive(text: "We cannot ship yet.", start: 10.05, end: 13,
                                     isFinal: false, resultsFinalizationTime: 10, source: "会议声音")
        let final = mapper.receive(text: "We cannot ship yet.", start: 10.05, end: 13,
                                   isFinal: true, resultsFinalizationTime: 13, source: "会议声音")
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(revised.count, 1)
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(first[0].segment.id, revised[0].segment.id)
        XCTAssertEqual(first[0].segment.id, final[0].segment.id)
        XCTAssertEqual(final[0].segment.text, "We cannot ship yet.")
        XCTAssertEqual(final[0].segment.source, "会议声音")
        XCTAssertTrue(final[0].isFinal)
        XCTAssertFalse(mapper.hasPendingText)
    }

    func testWatermarkFinalizesUnchangedPreviousPhraseWithoutReissuedFinal() {
        var mapper = AppleSpeechResultMapper()
        let first = mapper.receive(text: "第一句。", start: 0, end: 2, isFinal: false,
                                   resultsFinalizationTime: 0, source: "麦克风")[0]
        let second = mapper.receive(text: "第二句", start: 3, end: 4, isFinal: false,
                                    resultsFinalizationTime: 2.5, source: "麦克风")
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second[1].segment.id, first.segment.id)
        XCTAssertTrue(second[1].isFinal)
        XCTAssertFalse(second[0].isFinal)
        let tail = mapper.finishSuccessfully()
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail[0].segment.text, "第二句")
        XCTAssertTrue(tail[0].isFinal)
    }

    func testWiderRevisionRetractsCoveredOldIDsAndEmptyResultRetractsTail() {
        var mapper = AppleSpeechResultMapper()
        let first = mapper.receive(text: "Alpha", start: 0, end: 1, isFinal: false,
                                   resultsFinalizationTime: 0, source: nil)[0]
        let second = mapper.receive(text: "Beta", start: 1.5, end: 2, isFinal: false,
                                    resultsFinalizationTime: 0, source: nil)[0]
        let merged = mapper.receive(text: "Alpha and beta.", start: 0, end: 2, isFinal: false,
                                    resultsFinalizationTime: 0, source: nil)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].segment.id, second.segment.id)
        XCTAssertEqual(merged[0].segment.text, "")
        XCTAssertEqual(merged[1].segment.id, first.segment.id)
        let removed = mapper.receive(text: " \n ", start: 0, end: 2, isFinal: false,
                                     resultsFinalizationTime: 0, source: nil)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].segment.id, first.segment.id)
        XCTAssertEqual(removed[0].segment.text, "")
        XCTAssertFalse(mapper.hasPendingText)
    }

    func testOldResultsCannotReviveFinalizedRangesOrAnotherSource() {
        var microphone = AppleSpeechResultMapper()
        var system = AppleSpeechResultMapper()
        let mic = microphone.receive(text: "麦克风", start: 0, end: 2, isFinal: true,
                                     resultsFinalizationTime: 2, source: "麦克风")[0]
        XCTAssertTrue(microphone.receive(text: "旧回调", start: 0, end: 3, isFinal: false,
                                         resultsFinalizationTime: 0, source: "麦克风").isEmpty)
        let other = system.receive(text: "会议声音", start: 0, end: 2, isFinal: false,
                                   resultsFinalizationTime: 0, source: "会议声音")[0]
        XCTAssertNotEqual(mic.segment.id, other.segment.id)
        XCTAssertEqual(other.segment.start, 0)
        XCTAssertTrue(microphone.receive(text: "坏时间", start: .nan, end: 3, isFinal: false,
                                         resultsFinalizationTime: nil, source: nil).isEmpty)
    }

    func testPartialRangeCorrectionKeepsUntouchedPrefixAndSuffix() {
        var mapper = AppleSpeechResultMapper()
        let first = mapper.receive(
            text: "We can ship tomorrow.", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音",
            timedText: [
                .init(text: "We ", start: 0, end: 1),
                .init(text: "can ", start: 1, end: 2),
                .init(text: "ship ", start: 2, end: 3),
                .init(text: "tomorrow.", start: 3, end: 4)
            ]
        )[0]
        let corrected = mapper.receive(
            text: "cannot", start: 1, end: 2, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音"
        )
        var visible = [first.segment.id: first.segment]
        for update in corrected {
            if update.segment.text.isEmpty { visible.removeValue(forKey: update.segment.id) }
            else { visible[update.segment.id] = update.segment }
        }
        XCTAssertEqual(visible.values.sorted { $0.start < $1.start }.map(\.text),
                       ["We", "cannot", "ship tomorrow."])
        XCTAssertEqual(visible[first.segment.id]?.text, "We")
    }

    func testWatermarkCanSealTimedPrefixWhileKeepingUnchangedTail() {
        var mapper = AppleSpeechResultMapper()
        let first = mapper.receive(
            text: "First. Second.", start: 0, end: 4, isFinal: false,
            resultsFinalizationTime: 0, source: nil,
            timedText: [.init(text: "First. ", start: 0, end: 2),
                        .init(text: "Second.", start: 2, end: 4)]
        )[0]
        let progress = mapper.receive(text: "", start: 10, end: 10, isFinal: false,
                                      resultsFinalizationTime: 2, source: nil)
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress[0].segment.id, first.segment.id)
        XCTAssertEqual(progress[0].segment.text, "First.")
        XCTAssertTrue(progress[0].isFinal)
        XCTAssertEqual(progress[1].segment.text, "Second.")
        XCTAssertFalse(progress[1].isFinal)
        XCTAssertNotEqual(progress[1].segment.id, first.segment.id)
        let tail = mapper.finishSuccessfully()
        XCTAssertEqual(tail[0].segment.id, progress[1].segment.id)
    }

    func testInputTimelinePreservesMeetingGapsAndPreventsConversionOverlap() {
        var microphone = AppleSpeechInputTimeline()
        var system = AppleSpeechInputTimeline()
        XCTAssertEqual(microphone.place(duration: 0.100_062_5, requestedStart: 8), 8)
        XCTAssertEqual(microphone.place(duration: 0.1, requestedStart: 8.1), 8.100_062_5)
        XCTAssertEqual(microphone.place(duration: 0.1, requestedStart: 100), 100)
        XCTAssertEqual(microphone.place(duration: 0.1, requestedStart: nil), 100.1)
        XCTAssertEqual(system.place(duration: 0.1, requestedStart: 8), 8)
        XCTAssertNil(system.place(duration: .infinity, requestedStart: 9))
        XCTAssertEqual(system.end, 8.1)
    }

    func testAudioBudgetWaitsUntilConsumedAndDoubleConsumptionCannotFreeExtraSpace() {
        let budget = AppleSpeechInputBudget(maximumDuration: 2, maximumBytes: 100,
                                           maximumBuffers: 2)
        let first = budget.reserve(duration: 1, bytes: 40)!
        let second = budget.reserve(duration: 1, bytes: 40)!
        XCTAssertNil(budget.reserve(duration: 0.1, bytes: 1))
        budget.consumed(first)
        budget.consumed(first)
        XCTAssertNil(budget.reserve(duration: 1.1, bytes: 40))
        XCTAssertNil(budget.reserve(duration: 1, bytes: 61))
        XCTAssertNotNil(budget.reserve(duration: 1, bytes: 60))
        budget.consumed(second)
    }
}
