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

    func testTrailingSilenceCompletesCurrentSentenceAfterHypothesisAgreement() {
        var assembler = TranscriptSentenceAssembler()
        let words = [word("Thanks", 0, 0.5)]
        let first = assembler.update(words: words, replacingFrom: 0, observedThrough: 1.4,
                                     trailingSilenceFrom: 0.5)
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].isFinal)
        let second = assembler.update(words: words, replacingFrom: 0, observedThrough: 1.4,
                                      trailingSilenceFrom: 0.5)
        XCTAssertEqual(second[0].segment.id, first[0].segment.id)
        XCTAssertTrue(second[0].isFinal)
    }

    func testContinuousSpeechHasBoundedSentenceLengthAtWholeWordBoundary() {
        var assembler = TranscriptSentenceAssembler(maximumDuration: 10)
        let words = (0..<36).map { word($0 == 0 ? "word" : " word", Double($0), Double($0) + 0.9) }
        let changes = assembler.update(words: words, replacingFrom: 0, observedThrough: 36,
                                       stableThrough: 36)
        XCTAssertEqual(changes.count, 3)
        XCTAssertTrue(changes.dropLast().allSatisfy(\.isFinal))
        XCTAssertFalse(changes.last!.isFinal)
        XCTAssertTrue(changes.allSatisfy { $0.segment.end - $0.segment.start <= 16 })
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
        XCTAssertEqual(changes.map(\.segment.text), ["abcdefghij klmnopqrst tail"])
        XCTAssertFalse(changes[0].isFinal)
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

    func testFirstShortHypothesisWithRealSilenceCanStillBeCorrected() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(
            words: [word("reply count", 0, 0.8)], replacingFrom: 0, observedThrough: 2.5,
            trailingSilenceFrom: 0.9
        )
        XCTAssertEqual(first.count, 1)
        XCTAssertFalse(first[0].isFinal)
        let correctedWords = [word("retry count", 0.02, 0.82)]
        let corrected = assembler.update(
            words: correctedWords, replacingFrom: 0, observedThrough: 2.5,
            trailingSilenceFrom: 0.9
        )
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(corrected[0].segment.id, first[0].segment.id)
        XCTAssertEqual(corrected[0].segment.text, "retry count")
        XCTAssertFalse(corrected[0].isFinal)
        let confirmed = assembler.update(
            words: correctedWords, replacingFrom: 0, observedThrough: 2.5,
            trailingSilenceFrom: 0.9
        )
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertEqual(confirmed[0].segment.id, first[0].segment.id)
        XCTAssertEqual(confirmed[0].segment.text, "retry count")
        XCTAssertTrue(confirmed[0].isFinal)
    }

    func testActualFinishFlushesCorrectedTailWithoutWaitingForSecondAgreement() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(
            words: [word("reply count", 0, 0.8)], replacingFrom: 0, observedThrough: 2.5,
            trailingSilenceFrom: 0.9
        )
        let corrected = assembler.update(
            words: [word("retry count", 0.02, 0.82)], replacingFrom: 0, observedThrough: 2.5,
            trailingSilenceFrom: 0.9
        )
        XCTAssertFalse(first[0].isFinal)
        XCTAssertFalse(corrected[0].isFinal)
        let finished = assembler.finish()
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(finished[0].segment.id, first[0].segment.id)
        XCTAssertEqual(finished[0].segment.text, "retry count")
        XCTAssertTrue(finished[0].isFinal)
        XCTAssertTrue(assembler.finish().isEmpty)
    }

    func testSoftTenSecondTargetKeepsChineseNegationWithAmountUntilSentenceEnds() {
        var assembler = TranscriptSentenceAssembler()
        let prefix = [
            word("今天讨论发布计划", 0, 4), word("，预算", 4, 7),
            word("是", 7, 8), word("300", 8, 9), word("元", 9, 9.5),
            word("不是", 9.5, 10.2)
        ]
        let draft = assembler.update(words: prefix, replacingFrom: 0,
                                     observedThrough: 10.5, stableThrough: 11)
        XCTAssertEqual(draft.count, 1)
        XCTAssertFalse(draft[0].isFinal)
        let completed = assembler.update(
            words: prefix + [word("3000", 10.2, 10.8), word("元。", 10.8, 11.2)],
            replacingFrom: 0, observedThrough: 11.8, stableThrough: 12, source: "会议声音"
        )
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].segment.id, draft[0].segment.id)
        XCTAssertEqual(completed[0].segment.text, "今天讨论发布计划，预算是300元不是3000元。")
        XCTAssertEqual(completed[0].segment.source, "会议声音")
        XCTAssertTrue(completed[0].isFinal)
        XCTAssertTrue(assembler.finish().isEmpty)
    }

    func testSoftTargetKeepsCannotWriteWithItsExportedFileObject() {
        var assembler = TranscriptSentenceAssembler()
        let prefix = [word("Bedrock API key应该保存在钥匙串", 0, 8.5),
                      word("，不能", 8.5, 9.3), word("写", 9.3, 10.2)]
        let draft = assembler.update(words: prefix, replacingFrom: 0,
                                     observedThrough: 10.5, stableThrough: 11)
        XCTAssertEqual(draft.count, 1)
        XCTAssertFalse(draft[0].isFinal)
        let completed = assembler.update(
            words: prefix + [word("进", 10.2, 10.5), word("导出的文件。", 10.5, 12)],
            replacingFrom: 0, observedThrough: 12.5, stableThrough: 13
        )
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed[0].segment.id, draft[0].segment.id)
        XCTAssertEqual(completed[0].segment.text, "Bedrock API key应该保存在钥匙串，不能写进导出的文件。")
        XCTAssertTrue(completed[0].isFinal)
    }

    func testLongEnglishChoosesClauseBeforeWhileAndKeepsFinishesWithTheTest() {
        var assembler = TranscriptSentenceAssembler()
        let words = [
            word("We will keep reviewing the release window", 0, 7.5),
            word(" while", 7.5, 8), word(" Li", 8, 8.5), word(" Ming", 8.5, 9),
            word(" finishes", 9, 10.5), word(" the", 10.5, 10.9),
            word(" test", 10.9, 11.5), word(" tomorrow", 11.5, 12.8),
            word(" at", 12.8, 13.1), word(" ten", 13.1, 14),
            word(" and", 14, 14.3), word(" shares", 14.3, 15),
            word(" results.", 15, 15.99)
        ]
        let changes = assembler.update(words: words, replacingFrom: 0,
                                       observedThrough: 16.5, stableThrough: 17)
        XCTAssertEqual(changes.map(\.segment.text),
                       ["We will keep reviewing the release window",
                        "while Li Ming finishes the test tomorrow at ten and shares results."])
        XCTAssertTrue(changes.allSatisfy(\.isFinal))
        XCTAssertEqual(changes[0].segment.end, 7.5)
        XCTAssertTrue(assembler.finish().isEmpty)
    }

    func testSoftTargetUsesPreviousSafeCommaAndCarriesOriginalTailAcrossWindow() {
        var assembler = TranscriptSentenceAssembler()
        let words = [word("We reviewed the first topic,", 0, 7),
                     word(" another topic", 7, 11.7)]
        let first = assembler.update(words: words, replacingFrom: 0,
                                     observedThrough: 12.2, stableThrough: 12)
        XCTAssertEqual(first.map(\.segment.text), ["We reviewed the first topic,", "another topic"])
        guard first.count == 2 else { return }
        XCTAssertTrue(first[0].isFinal)
        XCTAssertFalse(first[1].isFinal)
        let later = assembler.update(
            words: [word(" needs review.", 12, 13)], replacingFrom: 12,
            observedThrough: 13.5, stableThrough: 14
        )
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later[0].segment.id, first[1].segment.id)
        XCTAssertEqual(later[0].segment.text, "another topic needs review.")
        XCTAssertTrue(later[0].isFinal)
    }

    func testHardFallbackBacktracksBeforeNegationAndKeepsNumberWithUnit() {
        var assembler = TranscriptSentenceAssembler(maximumDuration: 1)
        let prefix = (0..<5).map { word($0 == 0 ? "话题" : "继续", Double($0), Double($0) + 0.8) }
        let words = prefix + [word("不是", 4.8, 5.1), word("3000", 5.1, 5.4), word("元", 5.4, 5.7)]
        let first = assembler.update(words: words, replacingFrom: 0,
                                     observedThrough: 6, stableThrough: 7)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(first[0].isFinal)
        XCTAssertFalse(first[1].isFinal)
        XCTAssertTrue(first[1].segment.text.contains("不是3000元"))
        XCTAssertFalse(first[0].segment.text.contains("不是"))
        let final = assembler.finish()
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final[0].segment.id, first[1].segment.id)
        XCTAssertTrue(final[0].isFinal)
        XCTAssertTrue(assembler.finish().isEmpty)
    }

    func testHardFallbackDoesNotSplitNumericMillisecondsOrChineseAmount() {
        for pair in [[" 300", " milliseconds"], ["300", "元"]] {
            var assembler = TranscriptSentenceAssembler(maximumDuration: 1)
            let words = (0..<5).map { word($0 == 0 ? "topic" : " topic", Double($0), Double($0) + 0.8) }
                + [word(pair[0], 4.8, 5.1), word(pair[1], 5.1, 5.6)]
            let changes = assembler.update(words: words, replacingFrom: 0,
                                           observedThrough: 6, stableThrough: 7)
            XCTAssertEqual(changes.count, 2)
            XCTAssertTrue(changes[1].segment.text.contains(pair.joined().trimmingCharacters(in: .whitespaces)))
            XCTAssertFalse(changes[0].segment.text.contains("300"))
        }
    }

    func testCharacterFallbackIsBoundedWithoutSplittingFinalDependentTail() {
        var assembler = TranscriptSentenceAssembler(maximumCharacters: 20)
        let words = [
            word("abcdefghij", 0, 0.5), word(" klmnopqrst", 0.5, 1),
            word(" uvwxyzabcd", 1, 1.5), word(" efghijklmn", 1.5, 2),
            word(" cannot", 2, 2.3), word(" write", 2.3, 2.6),
            word(" into", 2.6, 2.9), word(" the", 2.9, 3.2),
            word(" file", 3.2, 3.5)
        ]
        let changes = assembler.update(words: words, replacingFrom: 0,
                                       observedThrough: 4, stableThrough: 5)
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes[0].isFinal)
        XCTAssertFalse(changes[1].isFinal)
        XCTAssertTrue(changes[1].segment.text.contains("cannot write into the file"))
        XCTAssertEqual(changes.map(\.segment.text).joined(separator: " "), words.map(\.text).joined())
    }

    func testKnownPauseBetweenPredicateAndObjectDoesNotSealBrokenSentence() {
        var assembler = TranscriptSentenceAssembler()
        let changes = assembler.update(
            words: [word("不能写", 0, 2), word("进导出的文件。", 3, 5)],
            replacingFrom: 0, observedThrough: 5.5, stableThrough: 6
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].segment.text, "不能写进导出的文件。")
        XCTAssertTrue(changes[0].isFinal)
    }

    func testStandaloneModelPunctuationDoesNotBecomeCaptionOrPendingSentence() {
        for text in ["。", "…", "！？？", " \n .,;: “”。 "] {
            var assembler = TranscriptSentenceAssembler()
            XCTAssertTrue(assembler.update(words: [word(text, 80.223, 80.383)],
                                           replacingFrom: 80, observedThrough: 82,
                                           stableThrough: 82).isEmpty)
            XCTAssertFalse(assembler.hasPendingSentence)
            XCTAssertTrue(assembler.finish().isEmpty)
        }
    }

    func testSeparatePunctuationTokenWithinSentenceRemainsInOriginalText() {
        var assembler = TranscriptSentenceAssembler()
        let changes = assembler.update(
            words: [word("你好", 0, 0.5), word("，", 0.5, 0.6),
                    word("今天预算是300元", 0.6, 2), word("。", 2, 2.1)],
            replacingFrom: 0, observedThrough: 3, stableThrough: 3
        )
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].segment.text, "你好，今天预算是300元。")
        XCTAssertTrue(changes[0].isFinal)
    }

    func testPunctuationOnlyReplacementRetractsDraftWithoutCreatingSemanticContent() {
        var assembler = TranscriptSentenceAssembler()
        let first = assembler.update(words: [word("temporary hypothesis", 2, 3)],
                                     replacingFrom: 0, observedThrough: 3.2)
        let removed = assembler.update(words: [word("。", 2, 3)], replacingFrom: 0,
                                       observedThrough: 4, stableThrough: 4)
        XCTAssertEqual(removed.count, 1)
        XCTAssertEqual(removed[0].segment.id, first[0].segment.id)
        XCTAssertEqual(removed[0].segment.text, "")
        XCTAssertFalse(removed[0].isFinal)
        XCTAssertFalse(assembler.hasPendingSentence)
    }

    func testSeparateThousandsSeparatorIsNotMistakenForSafeClauseBoundary() {
        var assembler = TranscriptSentenceAssembler()
        let prefix = [
            word("The budget is", 0, 5), word(" 3", 5, 5.2), word(",", 5.2, 5.3),
            word("000", 5.3, 7), word(" yuan", 7, 10.5)
        ]
        let first = assembler.update(words: prefix, replacingFrom: 0,
                                     observedThrough: 11, stableThrough: 12)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].segment.text, "The budget is 3,000 yuan")
        XCTAssertFalse(first[0].isFinal)
        let final = assembler.finish()
        XCTAssertEqual(final.count, 1)
        XCTAssertEqual(final[0].segment.id, first[0].segment.id)
        XCTAssertEqual(final[0].segment.text, first[0].segment.text)
        XCTAssertTrue(final[0].isFinal)
    }
}
