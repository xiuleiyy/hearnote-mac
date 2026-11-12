import Foundation
import XCTest
@testable import HearNoteCore

final class WhisperWindowReconciliationTests: XCTestCase {
    private typealias Word = WhisperTranscriptCleaner.TimedWord

    private func word(_ text: String, _ start: Double, _ end: Double) -> Word {
        Word(start: start, end: end, text: text)
    }

    func testLargeInteriorOmissionRequiresOneConfirmationAndRetainsActualPreviousWords() {
        var policy = WhisperWindowReconciliationPolicy()
        let original = [
            word("今天", 0, 1), word("预算", 1, 2), word("300元", 2, 3),
            word("不是3000元", 3, 4), word("默认区域未定", 4, 5), word("钥匙串", 5, 6)
        ]
        _ = policy.reconcile(words: original, coreStart: 0, publicationEnd: 7, audioEnd: 7)
        let sparse = [original[0], original[5]]
        let first = policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 7, audioEnd: 7)
        XCTAssertTrue(first.requiresConfirmation)
        XCTAssertFalse(first.retainedInteriorWords)
        let confirmed = policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 7,
                                         audioEnd: 7, confirmed: true)
        XCTAssertFalse(confirmed.requiresConfirmation)
        XCTAssertTrue(confirmed.retainedInteriorWords)
        XCTAssertEqual(confirmed.words, original)
    }

    func testRetryCanRestoreLatestActualTextWithoutRetainingWrongEarlierWords() {
        var policy = WhisperWindowReconciliationPolicy()
        let earlier = [word("预算", 0, 1), word("三千", 1, 2), word("否定", 2, 3),
                       word("区域", 3, 4), word("钥匙串", 4, 5)]
        _ = policy.reconcile(words: earlier, coreStart: 0, publicationEnd: 6, audioEnd: 6)
        XCTAssertTrue(policy.reconcile(words: [earlier[0], earlier[4]], coreStart: 0,
                                        publicationEnd: 6, audioEnd: 6).requiresConfirmation)
        let corrected = [earlier[0], word("三百", 1, 2), earlier[2], earlier[3], earlier[4]]
        let resolved = policy.reconcile(words: corrected, coreStart: 0, publicationEnd: 6,
                                        audioEnd: 6, confirmed: true)
        XCTAssertEqual(resolved.words, corrected)
        XCTAssertFalse(resolved.retainedInteriorWords)
    }

    func testSameAudioSnapshotCannotRequestRepeatedOmissionConfirmations() {
        var policy = WhisperWindowReconciliationPolicy()
        let original = [word("开头", 0, 1), word("旧模型词一", 1, 2), word("旧模型词二", 2, 3),
                        word("旧模型词三", 3, 4), word("结尾", 4, 5)]
        _ = policy.reconcile(words: original, coreStart: 0, publicationEnd: 6, audioEnd: 6)
        let sparse = [original[0], original[4]]
        XCTAssertTrue(policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 6,
                                        audioEnd: 6).requiresConfirmation)
        _ = policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 6,
                             audioEnd: 6, confirmed: true)
        for _ in 0..<4 {
            let repeated = policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 6,
                                            audioEnd: 6)
            XCTAssertFalse(repeated.requiresConfirmation)
            XCTAssertEqual(repeated.words, original)
        }
        XCTAssertTrue(policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 7,
                                        audioEnd: 7).requiresConfirmation)
    }

    func testIsolatedSmallRetractionsAreNotMergedAcrossSurvivingWords() {
        var policy = WhisperWindowReconciliationPolicy()
        let original = (0..<7).map { word("模型词\($0)", Double($0), Double($0 + 1)) }
        _ = policy.reconcile(words: original, coreStart: 0, publicationEnd: 8, audioEnd: 8)
        let revised = [original[0], original[2], original[4], original[6]]
        let output = policy.reconcile(words: revised, coreStart: 0, publicationEnd: 8, audioEnd: 8)
        XCTAssertFalse(output.requiresConfirmation)
        XCTAssertFalse(output.retainedInteriorWords)
        XCTAssertEqual(output.words, revised)
    }

    func testTailRetractionAndEmptyResultDoNotBecomePermanentPartialText() {
        var policy = WhisperWindowReconciliationPolicy()
        let original = [word("Keep", 0, 1), word(" the", 1, 2), word(" wrong", 2, 3),
                        word(" tail", 3, 4)]
        _ = policy.reconcile(words: original, coreStart: 0, publicationEnd: 5, audioEnd: 5)
        let revised = policy.reconcile(words: Array(original.prefix(2)), coreStart: 0,
                                       publicationEnd: 5, audioEnd: 5)
        XCTAssertEqual(revised.words, Array(original.prefix(2)))
        XCTAssertFalse(revised.requiresConfirmation)
        XCTAssertTrue(policy.reconcile(words: [], coreStart: 0, publicationEnd: 5,
                                        audioEnd: 5).words.isEmpty)
    }

    func testBoundaryTimestampDriftKeepsPreviouslyPublishedWordInItsCore() {
        var policy = WhisperWindowReconciliationPolicy()
        let original = [word("not", 12.01, 12.31), word(" yet", 12.4, 12.8)]
        _ = policy.reconcile(words: original, coreStart: 0, publicationEnd: 15, audioEnd: 15)
        _ = policy.reconcile(words: [], coreStart: 0, publicationEnd: 12, audioEnd: 15)
        let shifted = [word("not", 11.7, 11.98), original[1]]
        let output = policy.reconcile(words: shifted, coreStart: 12, publicationEnd: 15, audioEnd: 15)
        XCTAssertEqual(output.words, original)
        XCTAssertEqual(output.words.filter { $0.text == "not" }.count, 1)
    }

    func testFusionAndAssemblerKeepStableIDForSparseMixedWindow() {
        var policy = WhisperWindowReconciliationPolicy()
        var assembler = TranscriptSentenceAssembler(maximumDuration: 30)
        let words = [word("这个", 0, 1), word(" API", 1, 2), word(" latency", 2, 3),
                     word("不能超过", 3, 4), word(" 300 milliseconds", 4, 5),
                     word("先不要上线", 5, 6)]
        let first = policy.reconcile(words: words, coreStart: 0, publicationEnd: 7, audioEnd: 7)
        let draft = assembler.update(words: first.words, replacingFrom: 0, observedThrough: 7)
        let sparse = [words[0], words[5]]
        XCTAssertTrue(policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 7,
                                        audioEnd: 7).requiresConfirmation)
        let next = policy.reconcile(words: sparse, coreStart: 0, publicationEnd: 7,
                                    audioEnd: 7, confirmed: true)
        let final = assembler.update(words: next.words, replacingFrom: 0, observedThrough: 7,
                                     stableThrough: 7, finishing: true)
        XCTAssertEqual(final[0].segment.id, draft[0].segment.id)
        XCTAssertEqual(final[0].segment.text, words.map(\.text).joined())
        XCTAssertTrue(final[0].isFinal)
    }
}
