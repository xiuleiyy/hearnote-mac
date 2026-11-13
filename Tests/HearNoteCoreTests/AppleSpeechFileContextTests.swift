import Foundation
import XCTest
@testable import HearNoteCore

final class AppleSpeechFileContextTests: XCTestCase {
    func testPrefixCoversExactlyTwoSecondsInBoundedChunksWithoutSkippingFrames() throws {
        for sampleRate in [22_050.0, 44_100.0, 48_000.0] {
            let context = try XCTUnwrap(AppleSpeechFileContext(
                duration: 11.366_439_909, sampleRate: sampleRate
            ))
            XCTAssertEqual(context.prefixFrameCount, Int64(sampleRate * 2))
            XCTAssertEqual(context.prefixDuration, 2)
            XCTAssertEqual(context.originalDuration, 11.366_439_909)
            var nextFrame: Int64 = 0
            var previousEnd = 0.0
            while let chunk = context.prefixChunk(at: nextFrame) {
                XCTAssertEqual(chunk.frameOffset, nextFrame)
                XCTAssertGreaterThan(chunk.frameCount, 0)
                XCTAssertLessThanOrEqual(chunk.frameCount, 8192)
                XCTAssertEqual(chunk.start, previousEnd, accuracy: 0.000_000_001)
                nextFrame += Int64(chunk.frameCount)
                previousEnd = Double(nextFrame) / sampleRate
            }
            XCTAssertEqual(nextFrame, context.prefixFrameCount)
            XCTAssertEqual(previousEnd, 2, accuracy: 0.000_000_001)
            XCTAssertNil(context.prefixChunk(at: -1))
            XCTAssertNil(context.prefixChunk(at: context.prefixFrameCount + 1))
        }
    }

    func testFirstPhraseCrossingPrefixBoundaryKeepsNegationAndStableIdentity() throws {
        let context = try XCTUnwrap(AppleSpeechFileContext(duration: 11.366_439_909, sampleRate: 22_050))
        let original = TranscriptSegment(
            start: 1.091_519_274, end: 4.331_519_274,
            text: "We have not agreed on the launch date.", source: "录音"
        )
        let projected = try XCTUnwrap(context.project(original))
        XCTAssertEqual(projected.id, original.id)
        XCTAssertEqual(projected.text, original.text)
        XCTAssertEqual(projected.source, original.source)
        XCTAssertEqual(projected.start, 0)
        XCTAssertEqual(projected.end, 2.331_519_274, accuracy: 0.000_000_001)
        XCTAssertEqual(context.inputOffset(forOriginalOffset: 0), 2)
        XCTAssertEqual(context.inputOffset(forOriginalOffset: 8192.0 / 22_050),
                       2 + 8192.0 / 22_050)
    }

    func testAlreadySilentOriginalKeepsItsOwnSilenceAndDoesNotChangeMediaDuration() throws {
        let context = try XCTUnwrap(AppleSpeechFileContext(duration: 13.366_439_909, sampleRate: 22_050))
        let sourceSegment = TranscriptSegment(
            start: 3.091_519_274, end: 6.331_519_274,
            text: "We have not agreed on the launch date.", source: "录音"
        )
        let projected = try XCTUnwrap(context.project(sourceSegment))
        XCTAssertEqual(projected.start, 1.091_519_274, accuracy: 0.000_000_001)
        XCTAssertEqual(projected.end, 4.331_519_274, accuracy: 0.000_000_001)
        XCTAssertEqual(context.originalDuration, 13.366_439_909)
        XCTAssertEqual(context.inputOffset(forOriginalOffset: 2), 4)
    }

    func testPrefixOnlyTextIsExcludedButItsRetractionStillRemovesSameID() throws {
        let context = try XCTUnwrap(AppleSpeechFileContext(duration: 10, sampleRate: 22_050))
        let prefixOnly = TranscriptSegment(start: 0.25, end: 1.8, text: "Uh")
        let excluded = try XCTUnwrap(context.project(prefixOnly))
        XCTAssertEqual(excluded.id, prefixOnly.id)
        XCTAssertEqual(excluded.text, "")
        XCTAssertEqual(excluded.start, 0)
        XCTAssertEqual(excluded.end, 0)
        let endingAtBoundary = TranscriptSegment(start: 1.75, end: 2, text: ".")
        XCTAssertEqual(context.project(endingAtBoundary)?.text, "")
        var removal = prefixOnly
        removal.text = ""
        let projected = try XCTUnwrap(context.project(removal))
        XCTAssertEqual(projected.id, prefixOnly.id)
        XCTAssertEqual(projected.text, "")
        XCTAssertEqual(projected.start, 0)
        XCTAssertEqual(projected.end, 0)
        var visible = [prefixOnly.id: prefixOnly]
        if projected.text.isEmpty { visible.removeValue(forKey: projected.id) }
        XCTAssertTrue(visible.isEmpty)
    }

    func testPrefixOnlyRevisionRetractsPreviouslyVisibleCrossingPhraseWithoutRevivingIt() throws {
        let context = try XCTUnwrap(AppleSpeechFileContext(duration: 10, sampleRate: 22_050))
        let crossing = TranscriptSegment(
            start: 1.091_519_274, end: 4.331_519_274,
            text: "We have not agreed on the launch date.", source: "录音"
        )
        let visible = try XCTUnwrap(context.project(crossing))
        XCTAssertEqual(visible.text, crossing.text)
        var prefixRevision = crossing
        prefixRevision.end = 1.8
        prefixRevision.text = "Uh"
        let retraction = try XCTUnwrap(context.project(prefixRevision))
        XCTAssertEqual(retraction.id, crossing.id)
        XCTAssertEqual(retraction.source, crossing.source)
        XCTAssertEqual(retraction.text, "")
        XCTAssertEqual(retraction.start, 0)
        XCTAssertEqual(retraction.end, 0)
        // 非空、非法修订必须被忽略，不能伪装成撤回有效的可见语音。
        var invalidRevision = crossing
        invalidRevision.end = .nan
        XCTAssertNil(context.project(invalidRevision))
    }

    func testProjectionClampsConverterTailAndPreservesTranslationPayload() throws {
        let context = try XCTUnwrap(AppleSpeechFileContext(duration: 11.366_439_909, sampleRate: 22_050))
        let original = TranscriptSegment(
            start: 10.9, end: 13.427_706_774, text: "Li Ming will test tomorrow at 10 a.m.",
            source: "录音",
            translation: SegmentTranslation(
                sourceText: "Li Ming will test tomorrow at 10 a.m.",
                text: "李明明天上午十点测试。", targetLanguage: "简体中文"
            )
        )
        let projected = try XCTUnwrap(context.project(original))
        XCTAssertEqual(projected.start, 8.9, accuracy: 0.000_000_001)
        XCTAssertEqual(projected.end, context.originalDuration)
        XCTAssertEqual(projected.id, original.id)
        XCTAssertEqual(projected.translation, original.translation)
    }

    func testInvalidRangesAreRejectedButInvalidTombstoneStillCarriesDeletionIdentity() throws {
        let context = try XCTUnwrap(AppleSpeechFileContext(duration: 10, sampleRate: 22_050))
        for (start, end) in [
            (Double.nan, 4), (0, Double.infinity), (-1, 4), (4, 3)
        ] {
            let invalid = TranscriptSegment(start: start, end: end, text: "not approved")
            XCTAssertNil(context.project(invalid))
            var tombstone = invalid
            tombstone.text = " \n "
            let projected = try XCTUnwrap(context.project(tombstone))
            XCTAssertEqual(projected.id, invalid.id)
            XCTAssertEqual(projected.text, tombstone.text)
            XCTAssertEqual(projected.start, 0)
            XCTAssertEqual(projected.end, 0)
        }
        XCTAssertNil(context.inputOffset(forOriginalOffset: .nan))
        XCTAssertNil(context.inputOffset(forOriginalOffset: .infinity))
        XCTAssertNil(context.inputOffset(forOriginalOffset: -1))
        XCTAssertNil(context.inputOffset(forOriginalOffset: 10.001))
    }

    func testDisabledPrefixIsIdentityAndFractionalFramePrefixUsesActualFrameTime() throws {
        let disabled = try XCTUnwrap(AppleSpeechFileContext(
            duration: 10, sampleRate: 22_050, prefixSeconds: 0
        ))
        XCTAssertEqual(disabled.prefixFrameCount, 0)
        XCTAssertNil(disabled.prefixChunk(at: 0))
        XCTAssertEqual(disabled.inputOffset(forOriginalOffset: 0), 0)
        let segment = TranscriptSegment(start: 0, end: 2, text: "not approved")
        XCTAssertEqual(disabled.project(segment), segment)
        let rounded = try XCTUnwrap(AppleSpeechFileContext(
            duration: 10, sampleRate: 22_050, prefixSeconds: 0.000_001
        ))
        XCTAssertEqual(rounded.prefixFrameCount, 1)
        XCTAssertEqual(rounded.prefixDuration, 1.0 / 22_050)
        XCTAssertEqual(rounded.inputOffset(forOriginalOffset: 0), 1.0 / 22_050)
    }

    func testInvalidPoliciesCannotCreateUnboundedOrNonfiniteOffsets() {
        for (duration, rate, prefix) in [
            (-1.0, 22_050.0, 2.0),
            (Double.nan, 22_050, 2),
            (Double.infinity, 22_050, 2),
            (10, 0, 2),
            (10, Double.nan, 2),
            (10, Double.infinity, 2),
            (10, 22_050, -1),
            (10, 22_050, Double.nan),
            (10, 22_050, Double.infinity),
            (10, Double.greatestFiniteMagnitude, 2),
            (10, 1, Double(Int64.max)),
            (Double.greatestFiniteMagnitude, 0.5, Double.greatestFiniteMagnitude)
        ] {
            XCTAssertNil(AppleSpeechFileContext(
                duration: duration, sampleRate: rate, prefixSeconds: prefix
            ))
        }
    }
}
