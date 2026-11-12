import Foundation
import XCTest
@testable import HearNoteCore

final class WhisperDecodeSchedulingPolicyTests: XCTestCase {
    private typealias Word = TranscriptSentenceAssembler.TimedWord
    private let sampleRate = 16_000.0

    private func word(_ text: String, _ start: Double, _ end: Double) -> Word {
        Word(start: start, end: end, text: text)
    }

    private func pcm(speech: Double, silence: Double) -> [Float] {
        Array(repeating: 0.02, count: Int((speech * sampleRate).rounded()))
            + Array(repeating: 0, count: Int((silence * sampleRate).rounded()))
    }

    /// 模拟服务的一个真实调度入口：PCM -> decision -> 正文/前瞻 -> 组句。
    /// 未被 policy 允许的 tick 不会主动调用 assembler 来伪造一次确认。
    private struct Harness {
        var scheduling = WhisperDecodeSchedulingPolicy()
        var sentences = TranscriptSentenceAssembler(maximumDuration: 20)
        var coreStart = 0.0
        var lastDecodedEnd = 0.0
        var decodeCount = 0

        mutating func tick(
            samples: [Float], words: [Word], audioStart: Double = 0, complete: Bool = false
        ) -> (decision: WhisperDecodeSchedulingPolicy.Decision,
              updates: [TranscriptSentenceAssembler.Update])? {
            let audioEnd = audioStart + Double(samples.count) / 16_000
            let coreEnd = min(audioEnd, coreStart + 12)
            let silenceStart = WhisperDecodeSchedulingPolicy.trailingSilenceStart(
                samples: samples, audioStart: audioStart
            )
            guard let decision = scheduling.nextDecision(
                audioEnd: audioEnd, lastDecodedEnd: lastDecodedEnd, coreStart: coreStart,
                complete: complete, hasPendingSentence: sentences.hasPendingSentence,
                hasTrailingSilence: silenceStart != nil
            ) else { return nil }
            lastDecodedEnd = audioEnd
            decodeCount += 1
            let bodyEnd = WhisperDecodeSchedulingPolicy.publicationEnd(
                coreEnd: coreEnd, audioEnd: audioEnd, complete: complete,
                hasTrailingSilence: silenceStart != nil
            )
            let body = words.filter {
                let midpoint = ($0.start + $0.end) / 2
                return midpoint >= coreStart && midpoint < bodyEnd
            }
            let followingWord = words.first { ($0.start + $0.end) / 2 >= bodyEnd }
            let updates = sentences.update(
                words: body, replacingFrom: coreStart, observedThrough: audioEnd,
                stableThrough: complete ? coreEnd : coreStart, followingWord: followingWord,
                trailingSilenceFrom: silenceStart
            )
            return (decision, updates)
        }
    }

    func testQuietShortSnapshotCanDecodeAndConfirmWithoutNewAudio() throws {
        var harness = Harness()
        let samples = pcm(speech: 0.5, silence: 0.9)
        let words = [word("Thanks", 0, 0.5)]
        let first = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertEqual(first.decision, .newQuietSnapshot)
        XCTAssertFalse(first.updates[0].isFinal)
        XCTAssertTrue(harness.sentences.hasPendingSentence)

        let confirmed = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertEqual(confirmed.decision, .quietConfirmation)
        XCTAssertTrue(confirmed.updates[0].isFinal)
        XCTAssertEqual(confirmed.updates[0].segment.id, first.updates[0].segment.id)
        XCTAssertFalse(harness.sentences.hasPendingSentence)
        XCTAssertNil(harness.tick(samples: samples, words: words))
        XCTAssertEqual(harness.decodeCount, 2)
    }

    func testInitialWrongWordsCanReviseBeforeSecondBoundedConfirmation() throws {
        var harness = Harness()
        let samples = pcm(speech: 0.5, silence: 0.9)
        let first = try XCTUnwrap(harness.tick(
            samples: samples, words: [word("上海预算", 0, 0.5)]
        ))
        let corrected = try XCTUnwrap(harness.tick(
            samples: samples, words: [word("上限预算", 0, 0.5)]
        ))
        XCTAssertFalse(first.updates[0].isFinal)
        XCTAssertFalse(corrected.updates[0].isFinal)
        XCTAssertEqual(corrected.updates[0].segment.id, first.updates[0].segment.id)

        let confirmed = try XCTUnwrap(harness.tick(
            samples: samples, words: [word("上限预算", 0, 0.5)]
        ))
        XCTAssertEqual(confirmed.updates[0].segment.text, "上限预算")
        XCTAssertTrue(confirmed.updates[0].isFinal)
        XCTAssertEqual(confirmed.updates[0].segment.id, first.updates[0].segment.id)
        XCTAssertNil(harness.tick(samples: samples, words: [word("上限预算", 0, 0.5)]))
        XCTAssertEqual(harness.decodeCount, 3)
    }

    func testNextQuietShortSentenceCanDecodeAfterPreviousSentenceWasFinalized() throws {
        var harness = Harness()
        let firstSamples = pcm(speech: 0.5, silence: 0.9)
        let firstWords = [word("First point", 0, 0.5)]
        let firstDraft = try XCTUnwrap(harness.tick(samples: firstSamples, words: firstWords))
        let firstFinal = try XCTUnwrap(harness.tick(samples: firstSamples, words: firstWords))
        XCTAssertTrue(firstFinal.updates[0].isFinal)
        XCTAssertFalse(harness.sentences.hasPendingSentence)
        XCTAssertGreaterThan(harness.lastDecodedEnd, harness.coreStart)
        XCTAssertNil(harness.tick(samples: firstSamples, words: firstWords))

        // 同一核心窗口追加 0.9 秒讲话；没有静音时不足 2.5 秒，不重复启动识别。
        let secondWords = firstWords + [word(" Second point", 1.4, 2.3)]
        let speakingSamples = firstSamples + pcm(speech: 0.9, silence: 0)
        XCTAssertNil(harness.tick(samples: speakingSamples, words: secondWords))

        // 新增总计 1.8 秒语音与真实尾静音后停帧，第二句仍可独立初识别和确认。
        let stoppedSamples = firstSamples + pcm(speech: 0.9, silence: 0.9)
        let secondDraft = try XCTUnwrap(harness.tick(samples: stoppedSamples, words: secondWords))
        XCTAssertEqual(secondDraft.decision, .newQuietSnapshot)
        XCTAssertEqual(secondDraft.updates.count, 1)
        XCTAssertEqual(secondDraft.updates[0].segment.text, "Second point")
        XCTAssertFalse(secondDraft.updates[0].isFinal)
        XCTAssertNotEqual(secondDraft.updates[0].segment.id, firstDraft.updates[0].segment.id)

        let secondFinal = try XCTUnwrap(harness.tick(samples: stoppedSamples, words: secondWords))
        XCTAssertEqual(secondFinal.decision, .quietConfirmation)
        XCTAssertTrue(secondFinal.updates[0].isFinal)
        XCTAssertEqual(secondFinal.updates[0].segment.id, secondDraft.updates[0].segment.id)
        XCTAssertFalse(harness.sentences.hasPendingSentence)
        XCTAssertNil(harness.tick(samples: stoppedSamples, words: secondWords))
        XCTAssertEqual(harness.decodeCount, 4)
    }

    func testInconsistentQuietSnapshotStopsAfterTwoAdditionalDecodesButCanFinish() throws {
        var harness = Harness()
        let samples = pcm(speech: 0.5, silence: 0.9)
        var originalID: UUID?
        for text in ["first", "second", "third"] {
            let attempt = try XCTUnwrap(harness.tick(
                samples: samples, words: [word(text, 0, 0.5)]
            ))
            XCTAssertFalse(attempt.updates[0].isFinal)
            originalID = originalID ?? attempt.updates[0].segment.id
            XCTAssertEqual(attempt.updates[0].segment.id, originalID)
        }
        XCTAssertNil(harness.tick(samples: samples, words: [word("fourth", 0, 0.5)]))
        XCTAssertTrue(harness.sentences.hasPendingSentence)
        XCTAssertEqual(harness.decodeCount, 3)

        let tail = harness.sentences.finish()
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail[0].segment.text, "third")
        XCTAssertEqual(tail[0].segment.id, originalID)
        XCTAssertTrue(tail[0].isFinal)
        XCTAssertFalse(harness.sentences.hasPendingSentence)
        XCTAssertTrue(harness.sentences.finish().isEmpty)
    }

    func testNoPcmSilenceCannotRepeatSnapshotDespitePendingPunctuation() throws {
        var harness = Harness()
        let samples = pcm(speech: 3, silence: 0)
        let words = [word("This looks complete.", 0, 2)]
        let first = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertEqual(first.decision, .newAudio)
        XCTAssertFalse(first.updates[0].isFinal)
        for _ in 0..<5 {
            XCTAssertNil(harness.tick(samples: samples, words: words))
        }
        XCTAssertEqual(harness.decodeCount, 1)
        XCTAssertTrue(harness.sentences.hasPendingSentence)
    }

    func testExactEightHundredMillisecondsOfPcmSilenceConfirmsSentence() throws {
        var harness = Harness()
        let samples = pcm(speech: 0.4, silence: 0.8)
        XCTAssertEqual(WhisperDecodeSchedulingPolicy.trailingSilenceStart(
            samples: samples, audioStart: 0
        ), 0.4)
        let words = [word("短句", 0, 0.4)]
        let first = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertFalse(first.updates[0].isFinal)
        let second = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertTrue(second.updates[0].isFinal)
        XCTAssertEqual(second.updates[0].segment.id, first.updates[0].segment.id)
    }

    func testOneSampleLessThanRequiredSilenceDoesNotAllowEarlyDecodeOrConfirmation() throws {
        let samples = pcm(speech: 0.4, silence: 0.8 - 1 / sampleRate)
        XCTAssertNil(WhisperDecodeSchedulingPolicy.trailingSilenceStart(
            samples: samples, audioStart: 0
        ))
        var short = Harness()
        XCTAssertNil(short.tick(samples: samples, words: [word("short", 0, 0.4)]))
        XCTAssertEqual(short.decodeCount, 0)

        var longer = Harness()
        let longerSamples = pcm(speech: 2, silence: 0.8 - 1 / sampleRate)
        let words = [word("still a draft", 0, 2)]
        let first = try XCTUnwrap(longer.tick(samples: longerSamples, words: words))
        XCTAssertFalse(first.updates[0].isFinal)
        XCTAssertNil(longer.tick(samples: longerSamples, words: words))
        XCTAssertEqual(longer.decodeCount, 1)
    }

    func testMoreThanRequiredPcmSilenceConfirmsMixedLanguageWithoutRewriting() throws {
        var harness = Harness()
        let samples = pcm(speech: 0.6, silence: 0.82)
        let words = [word("这个", 0, 0.2), word(" API latency", 0.2, 0.6)]
        let first = try XCTUnwrap(harness.tick(samples: samples, words: words))
        let second = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertFalse(first.updates[0].isFinal)
        XCTAssertTrue(second.updates[0].isFinal)
        XCTAssertEqual(second.updates[0].segment.text, "这个 API latency")
    }

    func testNewCapturedAudioResetsBoundedConfirmationBudget() throws {
        var harness = Harness()
        let initialSamples = pcm(speech: 0.5, silence: 0.9)
        for text in ["a", "b", "c"] {
            XCTAssertNotNil(harness.tick(samples: initialSamples, words: [word(text, 0, 0.5)]))
        }
        XCTAssertNil(harness.tick(samples: initialSamples, words: [word("c", 0, 0.5)]))

        let longerSamples = pcm(speech: 0.5, silence: 1)
        let confirmation = try XCTUnwrap(harness.tick(
            samples: longerSamples, words: [word("c", 0, 0.5)]
        ))
        XCTAssertEqual(confirmation.decision, .newQuietSnapshot)
        XCTAssertTrue(confirmation.updates[0].isFinal)
        XCTAssertEqual(harness.decodeCount, 4)
    }

    func testEnoughNewAudioCanDecodeAfterQuietConfirmationBudgetIsUsed() throws {
        var harness = Harness()
        let initialSamples = pcm(speech: 0.5, silence: 0.9)
        for text in ["a", "b", "c"] {
            XCTAssertNotNil(harness.tick(samples: initialSamples, words: [word(text, 0, 0.5)]))
        }
        let longer = try XCTUnwrap(harness.tick(
            samples: pcm(speech: 4, silence: 0),
            words: [word("continued speech", 0, 3.8)]
        ))
        XCTAssertEqual(longer.decision, .newAudio)
        XCTAssertFalse(longer.updates[0].isFinal)
        XCTAssertEqual(harness.decodeCount, 4)
    }

    func testCompleteWindowRemainsReachableAfterQuietBudgetIsUsed() throws {
        var harness = Harness()
        let samples = pcm(speech: 0.5, silence: 0.9)
        for text in ["a", "b", "c"] {
            XCTAssertNotNil(harness.tick(samples: samples, words: [word(text, 0, 0.5)]))
        }
        XCTAssertNil(harness.tick(samples: samples, words: [word("c", 0, 0.5)]))
        let complete = try XCTUnwrap(harness.tick(
            samples: samples, words: [word("c", 0, 0.5)], complete: true
        ))
        XCTAssertEqual(complete.decision, .completedWindow)
        XCTAssertTrue(complete.updates[0].isFinal)
    }

    func testSourcesAndNewSessionHaveIndependentConfirmationBudgets() throws {
        var system = Harness()
        var microphone = Harness()
        let samples = pcm(speech: 0.5, silence: 0.9)
        for text in ["a", "b", "c"] {
            XCTAssertNotNil(system.tick(samples: samples, words: [word(text, 0, 0.5)]))
        }
        XCTAssertNil(system.tick(samples: samples, words: [word("c", 0, 0.5)]))

        let microphoneFirst = try XCTUnwrap(microphone.tick(
            samples: samples, words: [word("my question", 0, 0.5)]
        ))
        let microphoneFinal = try XCTUnwrap(microphone.tick(
            samples: samples, words: [word("my question", 0, 0.5)]
        ))
        XCTAssertEqual(microphoneFirst.decision, .newQuietSnapshot)
        XCTAssertTrue(microphoneFinal.updates[0].isFinal)
        XCTAssertEqual(system.decodeCount, 3)

        system = Harness()
        let restarted = try XCTUnwrap(system.tick(
            samples: samples, words: [word("new session", 0, 0.5)]
        ))
        XCTAssertEqual(restarted.decision, .newQuietSnapshot)
        XCTAssertNotEqual(restarted.updates[0].segment.id, microphoneFirst.updates[0].segment.id)
    }

    func testQuietPartialIncludesLookaheadTailAndLaterCompleteWindowDoesNotRepeatIt() throws {
        var harness = Harness()
        let samples = pcm(speech: 12.2, silence: 0.8)
        let words = [word("The ongoing phrase", 10, 11.5), word(" continues here", 12, 12.2)]
        let first = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertEqual(first.updates.count, 1)
        XCTAssertEqual(first.updates[0].segment.text, "The ongoing phrase continues here")
        XCTAssertFalse(first.updates[0].isFinal)

        let final = try XCTUnwrap(harness.tick(samples: samples, words: words))
        XCTAssertEqual(final.updates[0].segment.id, first.updates[0].segment.id)
        XCTAssertTrue(final.updates[0].isFinal)
        XCTAssertFalse(harness.sentences.hasPendingSentence)

        let shiftedOldWords = [
            word("The ongoing phrase", 10.02, 11.52), word(" continues here", 12.05, 12.25)
        ]
        let complete = try XCTUnwrap(harness.tick(
            samples: pcm(speech: 15, silence: 0), words: shiftedOldWords, complete: true
        ))
        XCTAssertTrue(complete.updates.isEmpty)

        // 实际服务完整核心窗口推进到 12，保留 3 秒音频重叠。
        harness.coreStart = 12
        harness.lastDecodedEnd = 12
        let nextWindow = try XCTUnwrap(harness.tick(
            samples: pcm(speech: 5.2, silence: 0.8),
            words: shiftedOldWords + [word(" A new point", 13.5, 14.2)], audioStart: 9
        ))
        XCTAssertEqual(nextWindow.updates.count, 1)
        XCTAssertEqual(nextWindow.updates[0].segment.text, "A new point")
        XCTAssertNotEqual(nextWindow.updates[0].segment.id, first.updates[0].segment.id)
    }

    func testNonQuietPartialKeepsCoreBoundaryAndLookaheadPreventsFalseSilence() throws {
        var harness = Harness()
        let words = [word("The ongoing phrase", 10, 11.5), word(" continues here", 12, 12.2)]
        let first = try XCTUnwrap(harness.tick(
            samples: pcm(speech: 13, silence: 0), words: words
        ))
        XCTAssertEqual(first.updates[0].segment.text, "The ongoing phrase")
        XCTAssertFalse(first.updates[0].isFinal)
        XCTAssertEqual(WhisperDecodeSchedulingPolicy.publicationEnd(
            coreEnd: 12, audioEnd: 13, complete: false, hasTrailingSilence: false
        ), 12)
        XCTAssertEqual(WhisperDecodeSchedulingPolicy.publicationEnd(
            coreEnd: 12, audioEnd: 15, complete: true, hasTrailingSilence: true
        ), 12)
    }

    func testInvalidPcmEvidenceAndProgressDoNotTriggerQuietConfirmation() {
        XCTAssertNil(WhisperDecodeSchedulingPolicy.trailingSilenceStart(
            samples: Array(repeating: .nan, count: 16_000), audioStart: 0
        ))
        XCTAssertNil(WhisperDecodeSchedulingPolicy.trailingSilenceStart(
            samples: [0], audioStart: .nan
        ))
        XCTAssertNil(WhisperDecodeSchedulingPolicy.trailingSilenceStart(
            samples: [0], audioStart: 0, sampleRate: .infinity
        ))
        var scheduling = WhisperDecodeSchedulingPolicy()
        XCTAssertNil(scheduling.nextDecision(
            audioEnd: .nan, lastDecodedEnd: 0, coreStart: 0, complete: false,
            hasPendingSentence: true, hasTrailingSilence: true
        ))
        XCTAssertNil(scheduling.nextDecision(
            audioEnd: 0, lastDecodedEnd: 0, coreStart: 0, complete: true,
            hasPendingSentence: true, hasTrailingSilence: true
        ))
        XCTAssertNil(scheduling.nextDecision(
            audioEnd: 2, lastDecodedEnd: 2, coreStart: 3, complete: false,
            hasPendingSentence: true, hasTrailingSilence: true
        ))
    }
}
