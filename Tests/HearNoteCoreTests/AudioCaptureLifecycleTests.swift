import Foundation
import XCTest
@testable import HearNoteCore

final class AudioCaptureLifecycleTests: XCTestCase {
    func testStreamFailureIsNotGloballySuppressedByShutdownCode() {
        var lifecycle = AudioCaptureLifecycle()
        XCTAssertTrue(lifecycle.acceptsInput)
        XCTAssertEqual(lifecycle.streamErrorDisposition, .recordingFailure)
        lifecycle.beginStopping()
        XCTAssertFalse(lifecycle.acceptsInput)
        XCTAssertEqual(lifecycle.streamErrorDisposition, .shutdownWarning)
        lifecycle.beginStopping()
        XCTAssertEqual(lifecycle.streamErrorDisposition, .shutdownWarning)
        lifecycle.finish()
        XCTAssertFalse(lifecycle.acceptsInput)
        XCTAssertEqual(lifecycle.streamErrorDisposition, .ignore)
    }

    func testQueuedTailFramesArePreservedAndPostStopFramesRejected() {
        var lifecycle = AudioCaptureLifecycle()
        lifecycle.beginStopping(at: 12)
        XCTAssertEqual(lifecycle.acceptedFrameCount(start: 11.5, sampleRate: 48_000, frames: 4_800), 4_800)
        XCTAssertEqual(lifecycle.acceptedFrameCount(start: 11.95, sampleRate: 48_000, frames: 4_800), 2_400)
        XCTAssertEqual(lifecycle.acceptedFrameCount(start: 12.1, sampleRate: 48_000, frames: 4_800), 0)
        lifecycle.beginStopping(at: 20)
        XCTAssertEqual(lifecycle.acceptedFrameCount(start: 12.1, sampleRate: 48_000, frames: 4_800), 0)
        lifecycle.finish()
        XCTAssertEqual(lifecycle.acceptedFrameCount(start: 11.5, sampleRate: 48_000, frames: 4_800), 0)
    }

    @MainActor
    func testConcurrentCleanupWaitersShareOneFlushAndResult() async {
        let operation = AudioCaptureStopOperation<Int>()
        let entered = expectation(description: "one stop entered")
        var completion: CheckedContinuation<Int, Never>?
        var stops = 0
        let first = Task { @MainActor in
            await operation.run {
                stops += 1
                return await withCheckedContinuation { continuation in
                    completion = continuation
                    entered.fulfill()
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { @MainActor in
            await operation.run {
                stops += 1
                return -1
            }
        }
        first.cancel()
        completion?.resume(returning: 48_000)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult, 48_000)
        XCTAssertEqual(secondResult, 48_000)
        let later = await operation.run { -2 }
        XCTAssertEqual(later, 48_000)
        XCTAssertEqual(stops, 1)
    }
}
