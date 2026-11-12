import Foundation
import XCTest
@testable import HearNoteCore

final class WhisperTranscriptCleanerTests: XCTestCase {
    private typealias Word = WhisperTranscriptCleaner.TimedWord

    func testStandaloneTechnicalMarkerProducesNoTranscriptWords() {
        let input = [Word(start: 130, end: 133, text: " [BLANK_AUDIO] ")]
        XCTAssertTrue(WhisperTranscriptCleaner.removingBlankAudio(from: input).isEmpty)
        let split = [" [", "BLANK", "_", "AUDIO", "] "].enumerated().map {
            Word(start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
        }
        XCTAssertTrue(WhisperTranscriptCleaner.removingBlankAudio(from: split).isEmpty)
    }

    func testSplitMarkerAcrossSDKSegmentsPreservesRealWordsAndTimes() {
        let first = Word(start: 160, end: 160.6, text: "Fisshu")
        let last = Word(start: 163, end: 167, text: " tomorrow at 10 am.")
        let sdkSegments = [
            [first, Word(start: 160.6, end: 161, text: " ["), Word(start: 161, end: 161.2, text: "BLANK")],
            [Word(start: 161.2, end: 161.5, text: "_"), Word(start: 161.5, end: 162, text: "AUDIO"),
             Word(start: 162, end: 162.5, text: "]"), last]
        ]
        let cleaned = WhisperTranscriptCleaner.removingBlankAudio(from: sdkSegments.flatMap { $0 })
        XCTAssertEqual(cleaned, [first, last])
        XCTAssertEqual(cleaned.map(\.text).joined(), "Fisshu tomorrow at 10 am.")
    }

    func testMarkerInsideRealWordKeepsRemainingTextAndOriginalTimes() {
        let input = [Word(start: 130.25, end: 133.5, text: "到出的文件。 [BLANK_AUDIO]")]
        XCTAssertEqual(WhisperTranscriptCleaner.removingBlankAudio(from: input), [
            Word(start: 130.25, end: 133.5, text: "到出的文件。 ")
        ])
    }

    func testOrdinaryEnglishWordSpacesArePreservedExactly() {
        let input = [
            Word(start: 0, end: 0.3, text: "The"),
            Word(start: 0.3, end: 0.8, text: " release"),
            Word(start: 0.8, end: 1.1, text: " date"),
            Word(start: 1.1, end: 1.5, text: " is"),
            Word(start: 1.5, end: 2, text: " tomorrow.")
        ]
        let cleaned = WhisperTranscriptCleaner.removingBlankAudio(from: input)
        XCTAssertEqual(cleaned, input)
        XCTAssertEqual(cleaned.map(\.text).joined(), "The release date is tomorrow.")
    }

    func testRemovedMarkerWordCannotJoinAdjacentEnglishWords() {
        let first = Word(start: 0, end: 1, text: "Hello")
        let input = [
            first,
            Word(start: 1, end: 2, text: " [BLANK_AUDIO] "),
            Word(start: 2, end: 3, text: "world")
        ]
        let cleaned = WhisperTranscriptCleaner.removingBlankAudio(from: input)
        XCTAssertEqual(cleaned, [first, Word(start: 2, end: 3, text: "  world")])
        XCTAssertEqual(cleaned.map(\.text).joined(), "Hello  world")
        XCTAssertFalse(cleaned.map(\.text).joined().contains("Helloworld"))
    }

    func testLiteralBracketsAndOtherTermsRemainUntouched() {
        let text = "Use [API], array[0], BLANK_AUDIO, [BLANK_AUDIO_RATE], [blank_audio] and [BLANK AUDIO]."
        let input = [Word(start: 3, end: 8, text: text)]
        XCTAssertEqual(WhisperTranscriptCleaner.removingBlankAudio(from: input), input)
    }

    func testRepeatedMarkersPreserveUnicodeAndEnglishAcrossWordBoundaries() {
        let input = [
            Word(start: 1, end: 2, text: "😀在[BLANK_"),
            Word(start: 2, end: 3, text: "AUDIO]北京 🧪"),
            Word(start: 3, end: 4, text: " [BLANK_AUDIO] ready.")
        ]
        XCTAssertEqual(WhisperTranscriptCleaner.removingBlankAudio(from: input), [
            Word(start: 1, end: 2, text: "😀在"),
            Word(start: 2, end: 3, text: "北京 🧪"),
            Word(start: 3, end: 4, text: "  ready.")
        ])
    }

    func testCleanedRecognitionOutputExportsWithoutTechnicalMarker() throws {
        let input = [
            Word(start: 130, end: 133, text: "到出的文件。 [BLANK_AUDIO]"),
            Word(start: 160, end: 168, text: "Fisshu tomorrow at 10 am. [BLANK_AUDIO]")
        ]
        let cleaned = WhisperTranscriptCleaner.removingBlankAudio(from: input)
        let document = NoteDocument(segments: cleaned.map {
            TranscriptSegment(start: $0.start, end: $0.end,
                              text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                              source: "会议声音")
        }, sourceKind: .recording)
        let outputs = [
            TranscriptExporter.text(document),
            TranscriptExporter.srt(document),
            TranscriptExporter.markdown(document),
            String(decoding: try TranscriptExporter.json(document), as: UTF8.self)
        ]
        for output in outputs {
            XCTAssertFalse(output.contains("[BLANK_AUDIO]"))
            XCTAssertTrue(output.contains("到出的文件。"))
            XCTAssertTrue(output.contains("Fisshu tomorrow at 10 am."))
        }
        XCTAssertTrue(TranscriptExporter.srt(document).contains("00:02:10,000 --> 00:02:13,000"))
        XCTAssertTrue(TranscriptExporter.srt(document).contains("00:02:40,000 --> 00:02:48,000"))
    }

    func testExportDoesNotCleanLiteralMarkerInExistingUserNotes() {
        let document = NoteDocument(segments: [
            TranscriptSegment(text: "日志里记下了 [BLANK_AUDIO]。")
        ], sourceKind: .text)
        XCTAssertTrue(TranscriptExporter.text(document).contains("[BLANK_AUDIO]"))
        XCTAssertTrue(TranscriptExporter.srt(document).contains("[BLANK_AUDIO]"))
        XCTAssertTrue(TranscriptExporter.markdown(document).contains("[BLANK_AUDIO]"))
    }
}
