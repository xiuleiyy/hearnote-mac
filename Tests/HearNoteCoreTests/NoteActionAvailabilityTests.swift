import XCTest
@testable import HearNoteCore

final class NoteActionAvailabilityTests: XCTestCase {
    func testIdleDocumentWithOriginalAndMediaCanBeProcessed() {
        let context = NoteActionContext()
        XCTAssertNil(context.aiBlockReason(hasTranscript: true))
        XCTAssertNil(context.transcriptionBlockReason(hasMedia: true))
    }

    func testMissingOriginalAndMissingMediaRequireDifferentRecovery() {
        let context = NoteActionContext()
        XCTAssertEqual(context.aiBlockReason(hasTranscript: false), .missingTranscript)
        XCTAssertEqual(context.transcriptionBlockReason(hasMedia: false), .missingMedia)
        XCTAssertNil(context.aiBlockReason(hasTranscript: true))
    }

    func testActiveRecordingBlocksBothActionsEvenWhenOriginalExists() {
        let context = NoteActionContext(isRecording: true)
        XCTAssertEqual(context.aiBlockReason(hasTranscript: true), .recording)
        XCTAssertEqual(context.transcriptionBlockReason(hasMedia: true), .recording)
    }

    func testStartingAndSavingReportTheirActualMeetingStage() {
        let starting = NoteActionContext(isStartingRecording: true, isRecording: true)
        let saving = NoteActionContext(isStoppingRecording: true, isRecording: true)
        XCTAssertEqual(starting.aiBlockReason(hasTranscript: true), .startingRecording)
        XCTAssertEqual(starting.transcriptionBlockReason(hasMedia: true), .startingRecording)
        XCTAssertEqual(saving.aiBlockReason(hasTranscript: true), .stoppingRecording)
        XCTAssertEqual(saving.transcriptionBlockReason(hasMedia: true), .stoppingRecording)
    }

    func testTaskRemainsBlockedUntilCancellationActuallyFinishes() {
        var context = NoteActionContext(isProcessing: true)
        XCTAssertEqual(context.aiBlockReason(hasTranscript: true), .processing)
        XCTAssertEqual(context.transcriptionBlockReason(hasMedia: true), .processing)

        // 取消请求本身不代表后台任务已退出；完成后发布的新快照才恢复操作。
        XCTAssertEqual(context.aiBlockReason(hasTranscript: true), .processing)
        context.isProcessing = false
        XCTAssertNil(context.aiBlockReason(hasTranscript: true))
        XCTAssertNil(context.transcriptionBlockReason(hasMedia: true))
    }

    func testImportAndQuitAreVisibleInsteadOfSilentlyIgnoringClicks() {
        var importing = NoteActionContext(isImporting: true)
        XCTAssertEqual(importing.aiBlockReason(hasTranscript: true), .importing)
        importing.isImporting = false
        XCTAssertNil(importing.aiBlockReason(hasTranscript: true))

        let quitting = NoteActionContext(isQuitting: true, isRecording: true, isProcessing: true)
        XCTAssertEqual(quitting.aiBlockReason(hasTranscript: true), .quitting)
        XCTAssertEqual(quitting.transcriptionBlockReason(hasMedia: true), .quitting)
    }

    func testLifecycleBlockTakesPriorityOverMissingContent() {
        let recording = NoteActionContext(isRecording: true)
        let processing = NoteActionContext(isProcessing: true)
        XCTAssertEqual(recording.aiBlockReason(hasTranscript: false), .recording)
        XCTAssertEqual(recording.transcriptionBlockReason(hasMedia: false), .recording)
        XCTAssertEqual(processing.aiBlockReason(hasTranscript: false), .processing)
        XCTAssertEqual(processing.transcriptionBlockReason(hasMedia: false), .processing)
    }
}
