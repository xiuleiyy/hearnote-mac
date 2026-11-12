import Foundation
import XCTest
@testable import HearNoteCore

final class NoteTranslationContentTests: XCTestCase {
    func testLivePairedTranslationIsVisibleBeforeFullTextAggregation() {
        let first = translatedSegment(text: "Not approved.", translation: "尚未批准。")
        let second = TranscriptSegment(start: 3, end: 6, text: "Continue testing.")
        let document = NoteDocument(segments: [first, second], translation: "", sourceKind: .recording)

        let content = document.translationContent
        XCTAssertTrue(content.hasContent)
        XCTAssertNil(content.savedText)
        XCTAssertEqual(content.translatedSegments, [first])
        XCTAssertEqual(content.sourceSegmentCount, 2)
        XCTAssertEqual(content.untranslatedSegmentCount, 1)
    }

    func testStaleAndBlankPairedTranslationsDoNotEnterPreview() {
        var stale = translatedSegment(text: "Approved.", translation: "已批准。")
        stale.text = "Not approved."
        let blank = translatedSegment(text: "Continue testing.", translation: " \n\t\r\u{3000}")
        let document = NoteDocument(segments: [stale, blank])

        let content = document.translationContent
        XCTAssertFalse(content.hasContent)
        XCTAssertTrue(content.translatedSegments.isEmpty)
        XCTAssertEqual(content.untranslatedSegmentCount, 2)
    }

    func testPreviewPreservesPairedIdentityOrderingAndTargetLanguages() {
        let chinese = translatedSegment(text: "明天不要发布。", translation: "Do not release tomorrow.",
                                        targetLanguage: "英文", start: 5)
        let english = translatedSegment(text: "Keep the draft.", translation: "保留草稿。",
                                        targetLanguage: "中文", start: 5)
        let document = NoteDocument(segments: [chinese, english], sourceKind: .recording)

        let content = document.translationContent
        XCTAssertEqual(content.translatedSegments.map(\.id), [chinese.id, english.id])
        XCTAssertEqual(content.translatedSegments, [chinese, english])
        XCTAssertEqual(content.untranslatedSegmentCount, 0)
    }

    func testExistingFullTranslationIsPreservedExactlyWithoutPairedSegments() {
        let saved = "  [00:00] 尚未批准。\n\n[00:03] 继续测试。  "
        let document = NoteDocument(segments: [
            TranscriptSegment(text: "Not approved."),
            TranscriptSegment(text: "Continue testing.")
        ], translation: saved, translationLanguage: "中文")

        let content = document.translationContent
        XCTAssertTrue(content.hasContent)
        XCTAssertEqual(content.savedText, saved)
        XCTAssertTrue(content.translatedSegments.isEmpty)
    }

    func testWhitespaceSavedTextDoesNotHideAnExistingPairedTranslation() {
        let paired = translatedSegment(text: "Keep the draft.", translation: "保留草稿。")
        let document = NoteDocument(segments: [paired], translation: " \r\n\t\u{3000}")

        let content = document.translationContent
        XCTAssertNil(content.savedText)
        XCTAssertTrue(content.hasContent)
        XCTAssertEqual(content.translatedSegments, [paired])
    }

    func testOnlyWhitespaceOriginalIsNotProcessableOrCountedAsTranslated() {
        let blank = translatedSegment(text: " \n\t\u{3000}", translation: "虚构的译文。")
        let document = NoteDocument(segments: [blank])
        XCTAssertFalse(document.hasTranscriptText)
        XCTAssertFalse(document.translationContent.hasContent)
        XCTAssertEqual(document.translationContent.sourceSegmentCount, 0)
        XCTAssertEqual(document.translationContent.untranslatedSegmentCount, 0)
        XCTAssertEqual(NoteActionContext().aiBlockReason(hasTranscript: document.hasTranscriptText),
                       .missingTranscript)
    }

    func testUntranslatedOriginalProducesNoInventedTranslation() {
        let document = NoteDocument(segments: [
            TranscriptSegment(text: " \n"),
            TranscriptSegment(text: "Do not release tomorrow.")
        ])
        XCTAssertTrue(document.hasTranscriptText)
        XCTAssertFalse(document.translationContent.hasContent)
        XCTAssertNil(document.translationContent.savedText)
        XCTAssertEqual(document.translationContent.sourceSegmentCount, 1)
        XCTAssertEqual(document.translationContent.untranslatedSegmentCount, 1)
        XCTAssertNil(NoteActionContext().aiBlockReason(hasTranscript: document.hasTranscriptText))
    }

    func testReadingPreviewDoesNotMutateOrPopulateTheDocument() throws {
        let document = NoteDocument(
            segments: [translatedSegment(text: "Keep the draft.", translation: "保留草稿。")],
            translation: "", sourceKind: .recording
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(document)
        let first = document.translationContent
        XCTAssertEqual(document.translationContent, first)
        XCTAssertEqual(try encoder.encode(document), original)
        XCTAssertTrue(document.translation.isEmpty)
    }

    private func translatedSegment(
        text: String, translation: String, targetLanguage: String = "中文", start: Double = 0
    ) -> TranscriptSegment {
        TranscriptSegment(
            start: start, end: start + 3, text: text,
            translation: SegmentTranslation(sourceText: text, text: translation,
                                            targetLanguage: targetLanguage)
        )
    }
}
