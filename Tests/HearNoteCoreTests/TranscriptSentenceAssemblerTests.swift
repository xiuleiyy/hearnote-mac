import Foundation
import XCTest
@testable import HearNoteCore

final class TranscriptSentenceAssemblerTests: XCTestCase {
    private typealias Word = TranscriptSentenceAssembler.TimedWord
    private func word(_ text: String, _ start: Double, _ end: Double) -> Word {
        Word(start: start, end: end, text: text)
    }

    func testGrowingSentenceKeepsItsIDAndDoesNotBreakAtThreeSeconds() {
        var assembler = TranscriptSentenceAssembler()
        let prefix = [word("We", 0, 0.2), word(" have", 0.2, 1), word(" reviewed", 1, 2)]
        let first = assembler.update(words: prefix, replacingFrom: 0, observedThrough: 2.2)
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].isFinal)
        let second = assembler.update(
            words: prefix + [word(" the", 2, 2.5), word(" schedule.", 2.5, 3.7)],
            replacingFrom: 0, observedThrough: 4.1
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].segment.id, first[0].segment.id)
        XCTAssertEqual(second[0].segment.text, "We have reviewed the schedule.")
        XCTAssertFalse(second[0].isFinal)
        let agreed = assembler.update(
            words: prefix + [word(" the", 2, 2.5), word(" schedule.", 2.5, 3.7)],
            replacingFrom: 0, observedThrough: 4.1
        )
        XCTAssertEqual(agreed[0].segment.id, first[0].segment.id)
        XCTAssertTrue(agreed[0].isFinal)
    }

    func testUnfinishedSentenceContinuesAcrossDecoderWindowWithoutDuplication() {
        var assembler = TranscriptSentenceAssembler(maximumDuration: 20)
        let prefix = [word("This", 10, 10.4), word(" request", 10.4, 11.5)]
        let first = assembler.update(words: prefix, replacingFrom: 0, observedThrough: 11.7)
        let second = assembler.update(
            words: [word(" request", 10.4, 11.5), word(" needs", 12, 12.4),
                    word(" review.", 12.4, 13)],
            replacingFrom: 12, observedThrough: 13.5, stableThrough: 13.5
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].segment.id, first[0].segment.id)
        XCTAssertEqual(second[0].segment.text, "This request needs review.")
        XCTAssertTrue(second[0].isFinal)
    }

    func testActualPauseEndsSentenceEvenWithoutPunctuation() {
        var assembler = TranscriptSentenceAssembler()
        let changes = assembler.update(
            words: [word("First topic", 1, 2), word(" Next topic", 3, 4)],
            replacingFrom: 0, observedThrough: 4.2, stableThrough: 4.2
        )
        XCTAssertEqual(changes.map(\.segment.text), ["First topic", "Next topic"])
        XCTAssertTrue(changes[0].isFinal)
        XCTAssertFalse(changes[1].isFinal)
    }

    func testTrailingSilenceCompletesCurrentSentence() {
        var assembler = TranscriptSentenceAssembler()
        let words = [word("Thanks", 0, 0.5)]
        let first = assembler.update(words: words, replacingFrom: 0, observedThrough: 0.6)
        let second = assembler.update(words: words, replacingFrom: 0, observedThrough: 1.4,
                                      trailingSilenceFrom: 0.5)
        XCTAssertEqual(second[0].segment.id, first[0].segment.id)
        XCTAssertTrue(second[0].isFinal)
    }

    func testContinuousSpeechHasBoundedSentenceLengthAtWholeWordBoundary() {
        var assembler = TranscriptSentenceAssembler(maximumDuration: 10)
        let words = (0..<13).map { word($0 == 0 ? "word" : " word", Double($0), Double($0) + 0.9) }
        let changes = assembler.update(words: words, replacingFrom: 0, observedThrough: 13,
                                       stableThrough: 13)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes[0].isFinal)
        XCTAssertLessThanOrEqual(changes[0].segment.end, 10.9)
        XCTAssertEqual(changes.map(\.segment.text).joined(separator: " "), words.map(\.text).joined())
    }

    func testChineseAndMixedLanguageUseSentenceMarksAndPreserveTechnicalWords() {
        var assembler = TranscriptSentenceAssembler()
        let changes = assembler.update(
            words: [word("这个", 0, 0.2), word(" API", 0.2, 0.5),
                    word(" 的 latency 必须检查。", 0.5, 2),
                    word("Check the result!", 2.2, 3)],
            replacingFrom: 0, observedThrough: 3.5, stableThrough: 3.5
        )
        XCTAssertEqual(changes.map(\.segment.text),
                       ["这个 API 的 latency 必须检查。", "Check the result!"])
        XCTAssertTrue(changes.allSatisfy(\.isFinal))
    }

    func testDecimalAndAbbreviationsDoNotCreateArtificialSentenceBreaks() {
        var assembler = TranscriptSentenceAssembler()
        let words = [word("Dr.", 0, 0.2), word(" Chen", 0.2, 0.5),
                     word(" measured", 0.5, 1), word(" 3.", 1, 1.1),
                     word("5", 1.1, 1.2), word(" seconds", 1.2, 1.8),
                     word(" at", 1.8, 2), word(" 10", 2, 2.3),
                     word(" a.m.", 2.3, 2.7), word(" today.", 2.7, 3.4)]
        let changes = assembler.update(words: words, replacingFrom: 0, observedThrough: 4,
                                       stableThrough: 4)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].segment.text, "Dr. Chen measured 3.5 seconds at 10 a.m. today.")
        XCTAssertTrue(changes[0].isFinal)
    }

    func testPartialRevisionReusesIDAndDoesNotLeaveDuplicateText() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(words: [word("wrong phrase", 2, 3)],
                                     replacingFrom: 0, observedThrough: 3.2)
        let corrected = assembler.update(words: [word("correct phrase", 2.1, 3.1)],
                                         replacingFrom: 0, observedThrough: 3.3)
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(corrected[0].segment.id, first[0].segment.id)
        XCTAssertEqual(corrected[0].segment.text, "correct phrase")
        XCTAssertFalse(corrected[0].isFinal)
    }

    func testWithdrawnPartialExplicitlyRemovesItsID() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(words: [word("temporary text", 2, 3)],
                                     replacingFrom: 0, observedThrough: 3.2)
        let removed = assembler.update(words: [], replacingFrom: 0, observedThrough: 4)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].segment.id, first[0].segment.id)
        XCTAssertEqual(removed[0].segment.text, "")
    }

    func testSealedSentenceIsNotOverwrittenOrRepeatedByLaterSnapshot() {
        var assembler = TranscriptSentenceAssembler()
        let sealed = assembler.update(words: [word("Keep this.", 0, 1)],
                                      replacingFrom: 0, observedThrough: 1.5, stableThrough: 1.5)
        let later = assembler.update(
            words: [word("changed old sentence.", 0, 1), word(" Next", 1.1, 1.8)],
            replacingFrom: 0, observedThrough: 2
        )
        XCTAssertEqual(later.count, 1)
        XCTAssertNotEqual(later[0].segment.id, sealed[0].segment.id)
        XCTAssertEqual(later[0].segment.text, "Next")
    }

    func testFinishingFlushesTailAndKeepsOriginalID() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(words: [word("Unfinished tail", 2, 3)],
                                     replacingFrom: 0, observedThrough: 3.1)
        let final = assembler.finish(source: "会议声音")
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final[0].segment.id, first[0].segment.id)
        XCTAssertEqual(final[0].segment.text, "Unfinished tail")
        XCTAssertEqual(final[0].segment.source, "会议声音")
        XCTAssertTrue(final[0].isFinal)
        XCTAssertTrue(assembler.finish().isEmpty)
    }

    func testIndependentSourcesDoNotMergeSentencesOrIDs() {
        var microphone = TranscriptSentenceAssembler()
        var system = TranscriptSentenceAssembler()
        let first = microphone.update(words: [word("My question", 0, 1)],
                                      replacingFrom: 0, observedThrough: 1.2, source: "麦克风")
        let second = system.update(words: [word("Their reply", 0, 1)],
                                   replacingFrom: 0, observedThrough: 1.2, source: "会议声音")
        XCTAssertNotEqual(first[0].segment.id, second[0].segment.id)
        XCTAssertEqual(microphone.finish(source: "麦克风")[0].segment.text, "My question")
        XCTAssertEqual(system.finish(source: "会议声音")[0].segment.text, "Their reply")
    }

    func testCharacterBoundAndInvalidTimesAreHandledWithoutRewriting() {
        var assembler = TranscriptSentenceAssembler(maximumCharacters: 20)
        let changes = assembler.update(
            words: [word("abcdefghij", 0, 0.5), word(" klmnopqrst", 0.5, 1),
                    word(" tail", 1, 1.5), word(" invalid", .nan, 2)],
            replacingFrom: 0, observedThrough: 1.7, stableThrough: 1.7
        )
        XCTAssertEqual(changes.map(\.segment.text), ["abcdefghij klmnopqrst", "tail"])
        XCTAssertTrue(changes[0].isFinal)
        XCTAssertFalse(changes[1].isFinal)
    }

    func testEmptySnapshotsBeforeBoundaryCannotEraseCarriedPrefix() {
        var assembler = TranscriptSentenceAssembler(maximumDuration: 20)
        let first = assembler.update(words: [word("A carried phrase", 10, 11.5)],
                                     replacingFrom: 0, observedThrough: 11.7)
        let empty = assembler.update(words: [], replacingFrom: 12, observedThrough: 12)
        XCTAssertTrue(empty.isEmpty)
        let final = assembler.finish()
        XCTAssertEqual(final[0].segment.id, first[0].segment.id)
        XCTAssertEqual(final[0].segment.text, "A carried phrase")
    }

    func testTemporaryPartialPeriodDoesNotSealBeforeMoreCompleteHypothesis() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(
            words: [word("We have not agreed.", 0, 2)],
            replacingFrom: 0, observedThrough: 2.5
        )
        XCTAssertFalse(first[0].isFinal)
        let completeWords = [word("We have not agreed", 0, 2),
                             word(" on the schedule.", 2, 3)]
        let revised = assembler.update(words: completeWords, replacingFrom: 0, observedThrough: 3.5)
        XCTAssertEqual(revised.count, 1)
        XCTAssertEqual(revised[0].segment.id, first[0].segment.id)
        XCTAssertEqual(revised[0].segment.text, "We have not agreed on the schedule.")
        XCTAssertFalse(revised[0].isFinal)
        let agreed = assembler.update(words: completeWords, replacingFrom: 0, observedThrough: 3.5)
        XCTAssertEqual(agreed.count, 1)
        XCTAssertEqual(agreed[0].segment.id, first[0].segment.id)
        XCTAssertTrue(agreed[0].isFinal)
    }

    func testWindowLookaheadPreventsClippedCoreEndFromPretendingToBeSilence() {
        var assembler = TranscriptSentenceAssembler(maximumDuration: 20)
        let first = assembler.update(
            words: [word("The ongoing phrase", 10, 11.4)],
            replacingFrom: 0, observedThrough: 15, stableThrough: 12,
            followingWord: word(" continues", 11.9, 12.4), trailingSilenceFrom: 14
        )
        XCTAssertFalse(first[0].isFinal)
        let continuation = assembler.update(
            words: [word(" continues", 11.9, 12.4), word(" here.", 12.4, 13)],
            replacingFrom: 12, observedThrough: 13.5, stableThrough: 14
        )
        XCTAssertEqual(continuation.count, 1)
        XCTAssertEqual(continuation[0].segment.id, first[0].segment.id)
        XCTAssertEqual(continuation[0].segment.text, "The ongoing phrase continues here.")
        XCTAssertTrue(continuation[0].isFinal)
    }

    func testElapsedDecoderTimeWithoutActualSilenceCannotFinishPartialPhrase() {
        var assembler = TranscriptSentenceAssembler()
        let changes = assembler.update(
            words: [word("Still speaking", 0, 1)], replacingFrom: 0, observedThrough: 3
        )
        XCTAssertFalse(changes[0].isFinal)
    }

    func testShiftedSealedTailCannotRepeatButNextOverlappingWordIsPreserved() {
        var assembler = TranscriptSentenceAssembler()
        let sealed = assembler.update(
            words: [word("Keep", 0, 0.3), word(" this.", 0.3, 1)],
            replacingFrom: 0, observedThrough: 1.5, stableThrough: 1.5
        )
        XCTAssertTrue(sealed[0].isFinal)
        let later = assembler.update(
            words: [word("Keep", 0.05, 0.35), word(" this.", 0.35, 1.05),
                    word(" Next", 0.98, 1.4)],
            replacingFrom: 0, observedThrough: 1.6
        )
        XCTAssertEqual(later.count, 1)
        XCTAssertNotEqual(later[0].segment.id, sealed[0].segment.id)
        XCTAssertEqual(later[0].segment.text, "Next")
        XCTAssertEqual(later[0].segment.start, 0.98)
    }

    func testFileWindowLookaheadKeepsSplitDecimalWithinSameSentence() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(
            words: [word("The value is", 22, 23), word(" 3.", 23.2, 23.6)],
            replacingFrom: 0, observedThrough: 27, stableThrough: 24,
            followingWord: word("5", 24, 24.2)
        )
        XCTAssertFalse(first[0].isFinal)
        let later = assembler.update(
            words: [word("5", 24, 24.2), word(" units.", 24.2, 25)],
            replacingFrom: 24, observedThrough: 27, stableThrough: 27
        )
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later[0].segment.id, first[0].segment.id)
        XCTAssertEqual(later[0].segment.text, "The value is 3.5 units.")
        XCTAssertTrue(later[0].isFinal)
    }

    func testPreviouslyAcceptedOverlappingDraftIsNotRemovedByNextSnapshot() {
        var assembler = TranscriptSentenceAssembler()
        let words = [word("Keep", 0, 0.3), word(" this.", 0.3, 1),
                     word(" Next", 0.8, 1.1)]
        let first = assembler.update(words: words, replacingFrom: 0,
                                     observedThrough: 1.3, stableThrough: 1.5)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first[0].isFinal)
        XCTAssertFalse(first[1].isFinal)
        XCTAssertEqual(first[1].segment.text, "Next")
        let repeated = assembler.update(words: words, replacingFrom: 0,
                                        observedThrough: 1.3, stableThrough: 1.5)
        XCTAssertTrue(repeated.isEmpty)
        let final = assembler.finish()
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final[0].segment.id, first[1].segment.id)
        XCTAssertEqual(final[0].segment.text, "Next")
    }

    func testAcceptedOverlappingDraftRemainsRevisable() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(
            words: [word("Keep", 0, 0.3), word(" this.", 0.3, 1),
                    word(" Next", 0.8, 1.1)],
            replacingFrom: 0, observedThrough: 1.3, stableThrough: 1.5
        )
        let corrected = assembler.update(
            words: [word("Keep", 0, 0.3), word(" this.", 0.3, 1),
                    word(" Corrected", 0.82, 1.12)],
            replacingFrom: 0, observedThrough: 1.3, stableThrough: 1.5
        )
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(corrected[0].segment.id, first[1].segment.id)
        XCTAssertEqual(corrected[0].segment.text, "Corrected")
        XCTAssertFalse(corrected[0].isFinal)
    }
}
