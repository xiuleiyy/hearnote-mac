import XCTest
@testable import HearNoteCore

final class AppleSpeechAudioEvidenceTests: XCTestCase {
    func testCompletelyCoveredDigitalSilenceRejectsNativeWord() {
        var evidence = AppleSpeechAudioEvidence()
        for index in 0..<150 {
            evidence.record(start: Double(index) / 10, duration: 0.1, content: .exactlyZero)
        }
        XCTAssertFalse(evidence.accepts(text: "我", start: 1.68, end: 5.22))
        XCTAssertFalse(evidence.accepts(text: "To", start: 1.9, end: 13.62))
        XCTAssertEqual(evidence.rejectedZeroResultCount, 2)
    }

    func testUncoveredInputAndGapsFailOpen() {
        var evidence = AppleSpeechAudioEvidence()
        XCTAssertTrue(evidence.accepts(text: "word", start: 0, end: 1))
        evidence.record(start: 1, duration: 1, content: .exactlyZero)
        evidence.record(start: 3, duration: 1, content: .exactlyZero)
        XCTAssertTrue(evidence.accepts(text: "before", start: 0.9, end: 2))
        XCTAssertTrue(evidence.accepts(text: "gap", start: 1.5, end: 3.5))
        XCTAssertTrue(evidence.accepts(text: "future", start: 3.5, end: 4.1))
        XCTAssertEqual(evidence.rejectedZeroResultCount, 0)
    }

    func testUnknownPCMAndAnyNonzeroArePreserved() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 1, content: .exactlyZero)
        evidence.record(start: 1, duration: 1, content: .unknown)
        evidence.record(start: 2, duration: 1, content: .nonzero)
        XCTAssertTrue(evidence.accepts(text: "unknown", start: 0.5, end: 1.5))
        XCTAssertTrue(evidence.accepts(text: "quiet", start: 1.5, end: 2.5))
        XCTAssertTrue(evidence.accepts(text: "tail", start: 2.9, end: 3))
    }

    func testSourceAndSessionEvidenceRemainIndependent() {
        var microphone = AppleSpeechAudioEvidence()
        var system = AppleSpeechAudioEvidence()
        microphone.record(start: 0, duration: 10, content: .nonzero)
        system.record(start: 0, duration: 10, content: .exactlyZero)
        XCTAssertTrue(microphone.accepts(text: "my voice", start: 1, end: 2))
        XCTAssertFalse(system.accepts(text: "ghost", start: 1, end: 2))
        system = AppleSpeechAudioEvidence()
        XCTAssertTrue(system.accepts(text: "new run not yet covered", start: 1, end: 2))
        XCTAssertEqual(system.rejectedZeroResultCount, 0)
    }

    func testEmptyRevisionAndWatermarkStillReachMapper() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 4, content: .nonzero)
        evidence.record(start: 4, duration: 8, content: .exactlyZero)
        var mapper = AppleSpeechResultMapper()
        let first = mapper.receive(text: "Keep the timeout at 300 milliseconds.", start: 0, end: 4,
                                   isFinal: false, resultsFinalizationTime: 0, source: "麦克风")[0]
        let text = evidence.accepts(text: "To", start: 5, end: 10) ? "To" : ""
        let results = mapper.receive(text: text, start: 5, end: 10, isFinal: true,
                                     resultsFinalizationTime: 4, source: "麦克风")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].segment.id, first.segment.id)
        XCTAssertTrue(results[0].isFinal)
        XCTAssertTrue(evidence.accepts(text: " \n ", start: 5, end: 10))
        XCTAssertTrue(mapper.finishSuccessfully().isEmpty)
    }

    func testSilentPrerollDoesNotRemoveAFirstUtteranceAcrossBoundary() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 2, content: .exactlyZero)
        evidence.record(start: 2, duration: 3, content: .nonzero)
        XCTAssertFalse(evidence.accepts(text: "prefix ghost", start: 0.2, end: 1.9))
        XCTAssertTrue(evidence.accepts(text: "Do not launch.", start: 1.9, end: 4.7))
        XCTAssertTrue(evidence.accepts(text: "last word", start: 4.8, end: 5))
    }

    func testAudioAfterSilenceRecoversOnOriginalTimeline() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 20, content: .exactlyZero)
        XCTAssertFalse(evidence.accepts(text: "ghost", start: 3, end: 10))
        evidence.record(start: 20, duration: 1, content: .nonzero)
        XCTAssertTrue(evidence.accepts(text: "resume", start: 20, end: 21))
        XCTAssertFalse(evidence.accepts(text: "old silence", start: 3, end: 10))
    }

    func testConflictingOrOutOfOrderEvidenceCannotClaimSilence() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 4, content: .exactlyZero)
        evidence.record(start: 2, duration: 1, content: .nonzero)
        evidence.record(start: 1, duration: 1, content: .unknown)
        XCTAssertFalse(evidence.isConfirmedSilence(start: 1, end: 3))
        XCTAssertTrue(evidence.isConfirmedSilence(start: 3.5, end: 4))
    }

    func testBoundedForgottenHistoryBecomesUnknown() {
        var evidence = AppleSpeechAudioEvidence(maximumIntervals: 2)
        evidence.record(start: 0, duration: 1, content: .exactlyZero)
        evidence.record(start: 1, duration: 1, content: .nonzero)
        evidence.record(start: 2, duration: 1, content: .exactlyZero)
        XCTAssertTrue(evidence.accepts(text: "forgotten", start: 0, end: 0.9))
        XCTAssertFalse(evidence.accepts(text: "still known zero", start: 2, end: 3))
    }

    func testForgottenConflictingOverlapCannotTurnIntoConfirmedSilence() {
        var evidence = AppleSpeechAudioEvidence(maximumIntervals: 2)
        evidence.record(start: 0, duration: 10, content: .nonzero)
        evidence.record(start: 1, duration: 9, content: .exactlyZero)
        evidence.record(start: 11, duration: 1, content: .exactlyZero)
        XCTAssertTrue(evidence.accepts(text: "forgotten conflict", start: 2, end: 3))
        XCTAssertFalse(evidence.accepts(text: "still known zero", start: 11, end: 12))
    }

    func testMapperFinishRetractsPendingUnknownResultWithOriginalIdentity() throws {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 2, content: .exactlyZero)
        var mapper = AppleSpeechResultMapper()
        let temporary = try XCTUnwrap(mapper.receive(
            text: "To", start: 1.9, end: 5, isFinal: false,
            resultsFinalizationTime: 0, source: "系统声音"
        ).first)
        XCTAssertFalse(temporary.isFinal)
        XCTAssertEqual(evidence.validate(temporary), temporary)

        // The model initially reached beyond submitted PCM. Only the later
        // complete evidence can prove the whole pending range was digital zero.
        evidence.record(start: 2, duration: 4, content: .exactlyZero)
        let finalized = try XCTUnwrap(mapper.finishSuccessfully().first)
        XCTAssertTrue(finalized.isFinal)
        let retracted = evidence.validate(finalized)
        XCTAssertEqual(retracted.segment.id, temporary.segment.id)
        XCTAssertEqual(retracted.segment.start, temporary.segment.start)
        XCTAssertEqual(retracted.segment.end, temporary.segment.end)
        XCTAssertEqual(retracted.segment.source, temporary.segment.source)
        XCTAssertEqual(retracted.segment.text, "")
        XCTAssertTrue(retracted.isFinal)
        XCTAssertEqual(evidence.rejectedZeroResultCount, 1)
        XCTAssertTrue(mapper.finishSuccessfully().isEmpty)
    }

    func testMapperFinishPreservesNonzeroFirstUtteranceAndTailIdentity() throws {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 2, content: .exactlyZero)
        evidence.record(start: 2, duration: 1, content: .nonzero)
        evidence.record(start: 3, duration: 3, content: .exactlyZero)
        evidence.record(start: 6, duration: 1, content: .nonzero)
        var mapper = AppleSpeechResultMapper()
        let first = try XCTUnwrap(mapper.receive(
            text: "Do not launch.", start: 1.9, end: 2.8, isFinal: false,
            resultsFinalizationTime: 0, source: "麦克风"
        ).first)
        let tail = try XCTUnwrap(mapper.receive(
            text: "at ten a.m.", start: 6.5, end: 7, isFinal: false,
            resultsFinalizationTime: 0, source: "麦克风"
        ).first)
        XCTAssertEqual(evidence.validate(first), first)
        XCTAssertEqual(evidence.validate(tail), tail)
        let finalized = mapper.finishSuccessfully().map { evidence.validate($0) }
        XCTAssertEqual(finalized.count, 2)
        XCTAssertEqual(finalized.map(\.segment), [first.segment, tail.segment])
        XCTAssertTrue(finalized.allSatisfy(\.isFinal))
        XCTAssertEqual(evidence.rejectedZeroResultCount, 0)
    }

    func testNativeEmptyRevisionRetractsUnknownPendingAndPreservesRealNeighbors() throws {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 1, content: .nonzero)
        evidence.record(start: 1, duration: 1, content: .exactlyZero)
        var mapper = AppleSpeechResultMapper()
        let first = try XCTUnwrap(mapper.receive(
            text: "Keep the timeout.", start: 0.1, end: 0.8, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音"
        ).first)
        let uncertain = try XCTUnwrap(mapper.receive(
            text: "To", start: 1.9, end: 5, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音"
        ).first)
        XCTAssertEqual(evidence.validate(uncertain), uncertain)
        evidence.record(start: 2, duration: 3, content: .exactlyZero)
        evidence.record(start: 5, duration: 2, content: .nonzero)
        XCTAssertTrue(evidence.isConfirmedSilence(start: 1.9, end: 5))

        // A native empty revision is a withdrawal, not a new word to gate.
        // Preserve its existing identity even with complete zero evidence.
        let retractions = mapper.receive(
            text: "", start: 1.9, end: 5, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音"
        ).map { evidence.validate($0) }
        XCTAssertEqual(retractions.count, 1)
        let retracted = try XCTUnwrap(retractions.first)
        XCTAssertEqual(retracted.segment.id, uncertain.segment.id)
        XCTAssertEqual(retracted.segment.start, uncertain.segment.start)
        XCTAssertEqual(retracted.segment.end, uncertain.segment.end)
        XCTAssertEqual(retracted.segment.source, uncertain.segment.source)
        XCTAssertEqual(retracted.segment.text, "")
        XCTAssertFalse(retracted.isFinal)

        let tail = try XCTUnwrap(mapper.receive(
            text: "at three hundred milliseconds.", start: 5.2, end: 6.9, isFinal: false,
            resultsFinalizationTime: 0, source: "会议声音"
        ).first)
        let finalized = mapper.finishSuccessfully().map { evidence.validate($0) }
        XCTAssertEqual(finalized.map(\.segment), [first.segment, tail.segment])
        XCTAssertTrue(finalized.allSatisfy(\.isFinal))
        XCTAssertEqual(evidence.rejectedZeroResultCount, 0)
    }

    func testInvalidEvidenceAndRangesFailOpen() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: .nan, duration: 10, content: .exactlyZero)
        evidence.record(start: 0, duration: .infinity, content: .exactlyZero)
        evidence.record(start: -1, duration: 10, content: .exactlyZero)
        evidence.record(start: 0, duration: 0, content: .exactlyZero)
        XCTAssertTrue(evidence.accepts(text: "invalid", start: .nan, end: 3))
        XCTAssertTrue(evidence.accepts(text: "invalid", start: 0, end: .infinity))
        XCTAssertTrue(evidence.accepts(text: "invalid", start: -1, end: 3))
        XCTAssertTrue(evidence.accepts(text: "invalid", start: 3, end: 2))
        XCTAssertTrue(evidence.accepts(text: "uncovered", start: 0, end: 3))
    }

    func testZeroDurationResultRequiresActualCoverage() {
        var evidence = AppleSpeechAudioEvidence()
        evidence.record(start: 0, duration: 1, content: .exactlyZero)
        evidence.record(start: 1, duration: 1, content: .nonzero)
        XCTAssertFalse(evidence.accepts(text: "ghost", start: 0.5, end: 0.5))
        XCTAssertTrue(evidence.accepts(text: "speech boundary", start: 1, end: 1))
        XCTAssertTrue(evidence.accepts(text: "not yet covered", start: 2, end: 2))
    }
}
