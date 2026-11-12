import Foundation
import XCTest
@testable import HearNoteCore

final class TranslationHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testRoundTripPreservesFavoriteAndIdentityWithoutTouchingTheNoteLibrary() throws {
        let noteFile = root.appendingPathComponent("library.json")
        let noteData = Data("existing note library".utf8)
        try noteData.write(to: noteFile)
        let repository = TranslationHistoryRepository(root: root)
        XCTAssertEqual(try repository.load(), [])
        var entry = TranslationEntry(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123456),
            sourceText: "预算是300元，不是3000元。",
            translatedText: "The budget is 300 yuan, not 3,000 yuan.",
            sourceLanguage: "自动识别", targetLanguage: "英文",
            modelID: "global.anthropic.claude-sonnet-5-5"
        )
        try repository.save(entries: [entry])
        XCTAssertEqual(try repository.load(), [entry])
        entry.isFavorite = true
        try repository.save(entries: [entry])
        XCTAssertEqual(try repository.load(), [entry])
        XCTAssertEqual(try Data(contentsOf: noteFile), noteData)
    }

    func testDamagedHistoryCannotBeSilentlyClearedOrOverwritten() throws {
        let file = root.appendingPathComponent("translation-history.json")
        let damaged = Data("not valid JSON".utf8)
        try damaged.write(to: file)
        let repository = TranslationHistoryRepository(root: root)
        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? TranslationHistoryError, .unreadableHistory)
        }
        XCTAssertThrowsError(try repository.save(entries: [])) { error in
            XCTAssertEqual(error as? TranslationHistoryError, .unreadableHistory)
        }
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testFutureHistorySchemaIsPreserved() throws {
        let file = root.appendingPathComponent("translation-history.json")
        let future = Data(#"{"schemaVersion":99,"entries":[]}"#.utf8)
        try future.write(to: file)
        let repository = TranslationHistoryRepository(root: root)
        XCTAssertThrowsError(try repository.load()) { error in
            XCTAssertEqual(error as? TranslationHistoryError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try repository.save(entries: [])) { error in
            XCTAssertEqual(error as? TranslationHistoryError, .unsupportedVersion)
        }
        XCTAssertEqual(try Data(contentsOf: file), future)
    }
}
