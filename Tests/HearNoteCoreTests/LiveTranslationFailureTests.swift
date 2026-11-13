import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import HearNoteCore

final class LiveTranslationFailureTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    override func tearDown() {
        TranslationFailureProtocol.handler = nil
    }

    private func client() -> BedrockClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationFailureProtocol.self]
        return BedrockClient(
            configuration: .init(region: "us-east-1", modelID: "translation-fixture"),
            apiKey: "synthetic-stub-only",
            session: URLSession(configuration: configuration)
        )
    }

    private static func response(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "output": ["message": ["content": [["text": text]]]],
            "stopReason": "end_turn"
        ])
    }

    func testBadBilingualSegmentRetriesTwiceThenParksWhileOtherSourceContinues() async throws {
        let bad = TranscriptSegment(start: 0, end: 2,
                                    text: "The release date has not been decided.", source: "麦克风")
        let good = TranscriptSegment(start: 3, end: 4, text: "请继续会议。", source: "会议声音")
        let responses = [
            Self.response("The release date remains undecided."),
            Self.response("Please continue the meeting."),
            Self.response("The release date remains undecided."),
            Self.response("发布日期尚未确定。")
        ]
        var calls = 0
        TranslationFailureProtocol.handler = { _ in
            defer { calls += 1 }
            return (200, responses[calls])
        }
        var queue = LiveTranslationQueue()
        queue.update(bad, isFinal: true, now: origin)
        queue.update(good, isFinal: true, now: origin)
        let client = client()
        do {
            _ = try await client.translate(segments: [bad], targetLanguage: BedrockClient.bilingualLanguage)
            XCTFail("Rephrased English still violates the requested Chinese direction.")
        } catch {
            XCTAssertEqual(error as? BedrockError, .untranslatedInput)
            XCTAssertEqual(queue.recordFailure(error, for: bad, now: origin)?.recovery, .retry(after: 1))
        }
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(queue.next(now: origin), good)
        let translated = try await client.translate(segments: [good], targetLanguage: BedrockClient.bilingualLanguage)
        XCTAssertTrue(queue.commit(translated, for: good))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(1)), bad)
        do {
            _ = try await client.translate(segments: [bad], targetLanguage: BedrockClient.bilingualLanguage)
            XCTFail("The second invalid result must remain untranslated.")
        } catch {
            XCTAssertEqual(queue.recordFailure(error, for: bad, now: origin.addingTimeInterval(1))?.recovery,
                           .retryManually)
        }
        XCTAssertNil(queue.translation(for: bad))
        XCTAssertEqual(queue.translation(for: good), "Please continue the meeting.")
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(100), flush: true))
        queue.update(bad, isFinal: true, now: origin.addingTimeInterval(100))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(100), flush: true),
                     "Repeated final callbacks must not cause unlimited retries.")
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(queue.retry(bad, now: origin.addingTimeInterval(101)))
        let retried = try await client.translate(segments: [bad], targetLanguage: BedrockClient.bilingualLanguage)
        XCTAssertTrue(queue.commit(retried, for: bad))
        XCTAssertNil(queue.failure(for: bad))
        XCTAssertEqual(calls, 4)
    }

    func testAuthenticationPausesWithoutDroppingOtherPendingSegmentsOrRevisions() async {
        let first = TranscriptSegment(start: 0, text: "Please continue.")
        var second = TranscriptSegment(start: 1, text: "请保存录音。")
        TranslationFailureProtocol.handler = { _ in (403, Data("unused server body".utf8)) }
        var queue = LiveTranslationQueue()
        queue.update(first, isFinal: true, now: origin)
        queue.update(second, isFinal: true, now: origin)
        do {
            _ = try await client().translate(segments: [first], targetLanguage: BedrockClient.bilingualLanguage)
            XCTFail("HTTP 403 must fail.")
        } catch {
            let failure = queue.recordFailure(error, for: first, now: origin)
            XCTAssertEqual(failure?.category, .authentication)
            XCTAssertEqual(failure?.recovery, .pause)
            XCTAssertFalse(failure?.message.contains("unused server body") == true)
        }
        second.text = "请保留完整录音。"
        queue.update(second, isFinal: true, now: origin.addingTimeInterval(1))
        XCTAssertTrue(queue.isSuspended)
        XCTAssertTrue(queue.isPending(for: first))
        XCTAssertTrue(queue.isPending(for: second))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(100)))
        queue.resume()
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(100)), first)
        XCTAssertTrue(queue.commit("请继续。", for: first))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(100)), second)
    }

    func testHTTP429UsesGlobalCooldownAndCannotBeFlushedEarly() async {
        let first = TranscriptSegment(start: 0, text: "Please continue.")
        let second = TranscriptSegment(start: 1, text: "请继续。")
        TranslationFailureProtocol.handler = { _ in (429, Data()) }
        var queue = LiveTranslationQueue()
        queue.update(first, isFinal: true, now: origin)
        queue.update(second, isFinal: true, now: origin)
        do {
            _ = try await client().translate(segments: [first], targetLanguage: BedrockClient.bilingualLanguage)
            XCTFail("HTTP 429 must fail.")
        } catch {
            let failure = queue.recordFailure(error, for: first, now: origin)
            XCTAssertEqual(failure?.category, .rateLimited)
            XCTAssertEqual(failure?.recovery, .retry(after: 5))
        }
        XCTAssertFalse(queue.isSuspended)
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(4.9), flush: true))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(5)), first)
        XCTAssertTrue(queue.commit("请继续。", for: first))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(5)), second)
    }

    func testTypedTokenLimitUsesTheExistingGlobalCooldownAndBoundedRetryPolicy() {
        let error = BedrockError.throttled(.init(
            reason: .tokenLimit, requestID: nil, retryAfter: 30
        ))
        let first = TranscriptSegment(start: 0, text: "Please continue.")
        let second = TranscriptSegment(start: 1, text: "请继续。")
        var queue = LiveTranslationQueue()
        queue.update(first, isFinal: true, now: origin)
        queue.update(second, isFinal: true, now: origin)
        let firstFailure = queue.recordFailure(error, for: first, now: origin)
        XCTAssertEqual(firstFailure?.category, .rateLimited)
        XCTAssertEqual(firstFailure?.recovery, .retry(after: 5))
        XCTAssertFalse(queue.isSuspended)
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(4.9), flush: true))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(5)), first)
        let lastAttempt = origin.addingTimeInterval(5)
        XCTAssertEqual(queue.recordFailure(error, for: first, now: lastAttempt)?.recovery, .retryManually)
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(9.9), flush: true))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(10)), second)
        XCTAssertEqual(LiveTranslationFailurePolicy.failure(
            for: BedrockError.throttled(.init(reason: .rateLimit, requestID: nil, retryAfter: nil)),
            attempts: 1
        ).category, .rateLimited)
    }

    func testNetworkContentAndLanguageFailuresHaveSeparateBoundedPolicies() async {
        TranslationFailureProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        do {
            _ = try await client().testConnection()
            XCTFail("Stubbed network failure must fail.")
        } catch {
            XCTAssertEqual(LiveTranslationFailurePolicy.failure(for: error, attempts: 1).category, .network)
            XCTAssertEqual(LiveTranslationFailurePolicy.failure(for: error, attempts: 2).recovery, .retryManually)
        }
        XCTAssertEqual(LiveTranslationFailurePolicy.failure(for: BedrockError.invalidResponse, attempts: 1).category,
                       .modelContent)
        XCTAssertEqual(LiveTranslationFailurePolicy.failure(for: BedrockError.untranslatedInput, attempts: 1).category,
                       .languageRule)
        XCTAssertEqual(LiveTranslationFailurePolicy.failure(for: BedrockError.httpFailure(504), attempts: 1).category,
                       .service)
        XCTAssertEqual(LiveTranslationFailurePolicy.failure(for: BedrockError.contentFiltered, attempts: 1).recovery,
                       .retryManually)
    }

    func testTransportCancellationWithoutTaskCancellationParksInsteadOfRepeatingRequests() async {
        let segment = TranscriptSegment(text: "Please continue.")
        var queue = LiveTranslationQueue()
        queue.update(segment, isFinal: true, now: origin)
        TranslationFailureProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await client().translate(segments: [segment], targetLanguage: BedrockClient.bilingualLanguage)
            XCTFail("Cancelled transport must fail.")
        } catch {
            XCTAssertFalse(Task.isCancelled)
            let failure = queue.recordFailure(error, for: segment, now: origin)
            XCTAssertEqual(failure?.category, .unknown)
            XCTAssertEqual(failure?.recovery, .retryManually)
        }
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(100), flush: true))
        XCTAssertNil(queue.translation(for: segment))
        XCTAssertTrue(queue.retry(segment, now: origin.addingTimeInterval(101)))
    }

    func testManualRetryDoesNotBypassAnotherSegmentsRateLimitCooldown() {
        let first = TranscriptSegment(start: 0, text: "Please continue.")
        let second = TranscriptSegment(start: 1, text: "请继续。")
        var queue = LiveTranslationQueue()
        queue.update(first, isFinal: true, now: origin)
        queue.update(second, isFinal: true, now: origin)
        queue.recordFailure(BedrockError.untranslatedInput, for: second, now: origin)
        queue.recordFailure(BedrockError.untranslatedInput, for: second, now: origin)
        queue.recordFailure(BedrockError.httpFailure(429), for: first, now: origin)
        XCTAssertTrue(queue.retry(second, now: origin.addingTimeInterval(1)))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(4.9), flush: true))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(5)), first)
    }

    func testSecondRateLimitParksItsSegmentAndKeepsOtherRequestsInCooldown() {
        let first = TranscriptSegment(start: 0, text: "Please continue.")
        let second = TranscriptSegment(start: 1, text: "请继续。")
        var queue = LiveTranslationQueue()
        queue.update(first, isFinal: true, now: origin)
        queue.update(second, isFinal: true, now: origin)
        queue.recordFailure(BedrockError.httpFailure(429), for: first, now: origin)
        let secondAttempt = origin.addingTimeInterval(5)
        XCTAssertEqual(queue.next(now: secondAttempt), first)
        XCTAssertEqual(queue.recordFailure(BedrockError.httpFailure(429), for: first, now: secondAttempt)?.recovery,
                       .retryManually)
        XCTAssertFalse(queue.isPending(for: first))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(9.9), flush: true))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(10)), second)
        XCTAssertTrue(queue.retry(first, now: origin.addingTimeInterval(6)))
        XCTAssertNil(queue.next(now: origin.addingTimeInterval(9.9), flush: true))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(10)), first)
    }

    func testStoppingParksUnfinishedAndAutomaticallyRetryingSegmentsForManualRetry() {
        let unfinished = TranscriptSegment(start: 0, text: "Please continue.")
        let failed = TranscriptSegment(start: 1, text: "请继续。")
        var queue = LiveTranslationQueue()
        queue.update(unfinished, isFinal: false, now: origin, requiresFinal: true)
        queue.update(failed, isFinal: true, now: origin)
        let previousFailure = queue.recordFailure(BedrockError.untranslatedInput, for: failed, now: origin)
        queue.parkPendingForRetry()
        XCTAssertFalse(queue.hasPending)
        XCTAssertEqual(queue.failure(for: unfinished)?.recovery, .retryManually)
        XCTAssertEqual(queue.failure(for: failed)?.recovery, .retryManually)
        XCTAssertEqual(queue.failure(for: failed)?.message, previousFailure?.message)
        XCTAssertEqual(queue.failure(for: failed)?.category, .languageRule)
        XCTAssertFalse(queue.commit("Late response.", for: unfinished))
        XCTAssertNil(queue.translation(for: unfinished))
        XCTAssertTrue(queue.retry(unfinished, now: origin.addingTimeInterval(2)))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(2), flush: true), unfinished)
    }

    func testStoppingPreservesTheActualAuthenticationFailure() {
        let first = TranscriptSegment(start: 0, text: "Please continue.")
        let second = TranscriptSegment(start: 1, text: "请继续。")
        var queue = LiveTranslationQueue()
        queue.update(first, isFinal: true, now: origin)
        queue.update(second, isFinal: true, now: origin)
        let previousFailure = queue.recordFailure(BedrockError.httpFailure(403), for: first, now: origin)
        queue.parkPendingForRetry()
        XCTAssertEqual(queue.failure(for: first), previousFailure)
        XCTAssertEqual(queue.failure(for: second)?.recovery, .retryManually)
        XCTAssertFalse(queue.hasPending)
        XCTAssertTrue(queue.retry(first, now: origin.addingTimeInterval(1)))
        XCTAssertFalse(queue.isSuspended)
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(1)), first)
    }

    func testChineseWithProductTermsRequiresEnglishButPreservesChineseNamesAndNumbers() async throws {
        let source = "请把 Bedrock API key 保存在钥匙串，预算是300元。"
        let valid = "Please keep the Bedrock API key in 钥匙串; the budget is 300 yuan."
        TranslationFailureProtocol.handler = { _ in (200, Self.response(valid)) }
        let translated = try await client().translate(
            segments: [TranscriptSegment(text: source)], targetLanguage: BedrockClient.bilingualLanguage
        )
        XCTAssertEqual(translated, valid)
        TranslationFailureProtocol.handler = { _ in
            (200, Self.response("将 Bedrock API key 留在本机钥匙串，预算为300元。"))
        }
        do {
            _ = try await client().translate(
                segments: [TranscriptSegment(text: source)], targetLanguage: BedrockClient.bilingualLanguage
            )
            XCTFail("Retaining product terms does not make a Chinese paraphrase an English translation.")
        } catch { XCTAssertEqual(error as? BedrockError, .untranslatedInput) }
    }

    func testNumbersAndNamesCanRemainUnchangedAndShortEnglishStillRequiresChinese() async throws {
        for source in ["300", "AWS Bedrock API Key 300ms", "李明"] {
            TranslationFailureProtocol.handler = { _ in (200, Self.response(source)) }
            let result = try await client().translateText(source, targetLanguage: BedrockClient.bilingualLanguage)
            XCTAssertEqual(result, source)
        }
        TranslationFailureProtocol.handler = { _ in (200, Self.response("还没有。")) }
        let translated = try await client().translateText("Not yet.", targetLanguage: BedrockClient.bilingualLanguage)
        XCTAssertEqual(translated, "还没有。")
        TranslationFailureProtocol.handler = { _ in (200, Self.response("Not now.")) }
        do {
            _ = try await client().translateText("Not yet.", targetLanguage: BedrockClient.bilingualLanguage)
            XCTFail("Short English semantic text must not stay English.")
        } catch { XCTAssertEqual(error as? BedrockError, .untranslatedInput) }
    }

    func testRevisionAndRemovalInvalidateFailureAndRejectLateCommits() {
        var segment = TranscriptSegment(text: "Please continue.")
        var queue = LiveTranslationQueue()
        queue.update(segment, isFinal: true, now: origin)
        queue.recordFailure(BedrockError.untranslatedInput, for: segment, now: origin)
        queue.recordFailure(BedrockError.untranslatedInput, for: segment, now: origin.addingTimeInterval(1))
        let old = segment
        segment.text = "Please save the recording."
        queue.update(segment, isFinal: true, now: origin.addingTimeInterval(2))
        XCTAssertNil(queue.failure(for: segment))
        XCTAssertEqual(queue.next(now: origin.addingTimeInterval(2)), segment)
        XCTAssertFalse(queue.commit("Old response.", for: old))
        queue.remove(id: segment.id)
        XCTAssertNil(queue.failure(for: segment))
        XCTAssertFalse(queue.retry(segment, now: origin.addingTimeInterval(3)))
        XCTAssertFalse(queue.commit("Late response.", for: segment))
        XCTAssertFalse(queue.commit(" \n ", for: segment))
    }
}

private final class TranslationFailureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
