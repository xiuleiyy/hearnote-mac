import Foundation
import XCTest
@testable import HearNoteCore

final class SegmentTranslationTests: XCTestCase {
    func testOldSegmentWithoutTranslationStillDecodes() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","start":0,"end":1,"text":"尚未决定。"}
        """
        let segment = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
        XCTAssertEqual(segment.text, "尚未决定。")
        XCTAssertNil(segment.translation)
        XCTAssertNil(segment.validTranslation)
    }

    func testOldLibraryWithoutSegmentTranslationLoadsAndSaves() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldLibrary = """
        {
          "schemaVersion": 1,
          "documents": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "旧会议",
            "createdAt": 1000,
            "duration": 1,
            "segments": [{
              "id": "00000000-0000-0000-0000-000000000002",
              "start": 0,
              "end": 1,
              "text": "尚未决定。",
              "source": "会议声音"
            }],
            "summary": "",
            "translation": "[00:00] We have not decided.",
            "translationLanguage": "英文",
            "isFavorite": false,
            "sourceKind": "recording"
          }]
        }
        """
        try Data(oldLibrary.utf8).write(to: root.appendingPathComponent("library.json"))
        let repository = DocumentRepository(root: root)
        let documents = try repository.load()
        XCTAssertEqual(documents.count, 1)
        XCTAssertEqual(documents[0].translation, "[00:00] We have not decided.")
        XCTAssertNil(documents[0].segments[0].translation)
        try repository.save(documents)
        XCTAssertEqual(try repository.load(), documents)
    }

    func testRepositoryPreservesPairedTranslationsForSimultaneousAudioSources() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            start: 5, end: 8, text: "预算三百元。", source: "麦克风",
            translation: SegmentTranslation(
                sourceText: "预算三百元。", text: "The budget is 300 yuan.", targetLanguage: "英文"
            )
        )
        let meeting = TranscriptSegment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            start: 5, end: 8, text: "Do not launch tomorrow.", source: "会议声音",
            translation: SegmentTranslation(
                sourceText: "Do not launch tomorrow.", text: "明天不要上线。", targetLanguage: "中文"
            )
        )
        let document = NoteDocument(segments: [microphone, meeting], sourceKind: .recording)
        let repository = DocumentRepository(root: root)
        try repository.save([document])

        let restored = try XCTUnwrap(repository.load().first)
        XCTAssertEqual(restored, document)
        XCTAssertEqual(restored.segments[0].id, microphone.id)
        XCTAssertEqual(restored.segments[0].validTranslation?.text, "The budget is 300 yuan.")
        XCTAssertEqual(restored.segments[1].id, meeting.id)
        XCTAssertEqual(restored.segments[1].validTranslation?.text, "明天不要上线。")
        XCTAssertEqual(restored.segments[1].validTranslation?.targetLanguage, "中文")
    }

    func testRevisedNegationDoesNotDisplayOldTranslation() {
        var segment = translatedSegment()
        segment.text = "明天不发布。"
        XCTAssertNotNil(segment.translation)
        XCTAssertNil(segment.validTranslation)
    }

    func testTimestampRevisionKeepsMatchingTranslation() {
        var segment = translatedSegment()
        let original = segment.validTranslation
        segment.start = 2.5
        segment.end = 4.5
        XCTAssertEqual(segment.validTranslation, original)
    }

    func testEmptyAndWhitespaceTranslationsDoNotDisplay() {
        var segment = translatedSegment()
        for text in ["", " \n\t\r", "\u{3000}"] {
            segment.translation?.text = text
            XCTAssertNil(segment.validTranslation)
        }
    }

    func testPendingStateTracksCurrentTextAndClearsAfterCommitOrSuspend() {
        let now = Date(timeIntervalSince1970: 1_000)
        var queue = LiveTranslationQueue()
        let original = TranscriptSegment(text: "明天发布。")
        var corrected = original
        corrected.text = "明天不发布。"

        XCTAssertFalse(queue.isPending(for: original))
        queue.update(original, isFinal: false, now: now)
        XCTAssertTrue(queue.isPending(for: original))
        XCTAssertFalse(queue.isPending(for: corrected))
        queue.update(corrected, isFinal: true, now: now)
        XCTAssertFalse(queue.isPending(for: original))
        XCTAssertTrue(queue.isPending(for: corrected))
        XCTAssertTrue(queue.commit("Do not release tomorrow.", for: corrected))
        XCTAssertFalse(queue.isPending(for: corrected))

        let next = TranscriptSegment(text: "下一条。")
        queue.update(next, isFinal: true, now: now)
        XCTAssertTrue(queue.isPending(for: next))
        queue.suspend()
        XCTAssertFalse(queue.isPending(for: next))
        queue.resume()
        XCTAssertFalse(queue.isPending(for: next))
    }

    private func translatedSegment() -> TranscriptSegment {
        TranscriptSegment(
            text: "明天发布。",
            translation: SegmentTranslation(
                sourceText: "明天发布。", text: "Release tomorrow.", targetLanguage: "英文"
            )
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}
