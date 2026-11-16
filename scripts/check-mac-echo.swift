import AVFoundation
import CoreMedia
import Foundation

private enum HarnessFailure: Error { case assertion(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HarnessFailure.assertion(message) }
}

private func diagnostic(_ message: String) {
    // Write immediately so a following assertion/crash cannot hide CI evidence
    // in a buffered stdout stream. Only synthetic counts and timing go here.
    FileHandle.standardError.write(Data("[Mac echo check] \(message)\n".utf8))
}

/// Synthetic scheduling uses a logical monotonic clock. Advancing it is not a
/// measurement of the user's capture latency or of this CI machine's speed.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func now() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(to next: Double) {
        lock.lock()
        defer { lock.unlock() }
        precondition(next.isFinite && next >= value)
        value = next
    }
}

@MainActor
private final class Collector {
    var samples: [Float] = []
    var starts: [Double] = []
    var statuses: [String] = []
    func append(_ buffer: AVAudioPCMBuffer, at hostTime: Double) {
        starts.append(hostTime)
        if let data = buffer.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
    }
}

@main
struct MacEchoHarness {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearnote-echo-synthetic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await conversionWithoutReference(rate: 44_100, chunk: 2_048, root: root)
        try await conversionWithoutReference(rate: 48_000, chunk: 1_024, root: root)
        try await continuousReference(referenceRate: 48_000, microphoneRate: 44_100, root: root)
        try await continuousReference(referenceRate: 44_100, microphoneRate: 48_000, root: root)
        try await referenceCumulativeDrift(root: root)
        try await adaptationAfterReset(.missingReference, root: root)
        try await adaptationAfterReset(.invalidReference, root: root)
        try await adaptationAfterReset(.invalidMicrophone, root: root)
        try await adaptationAfterReset(.referenceFormat, root: root)
        try await lateReference(captureAge: 0, root: root)
        try await lateReference(captureAge: 0.25, root: root)
        try await wholePacketDeadline(root: root)
        try await largePacketConversion(rate: 44_100, root: root)
        try await largePacketConversion(rate: 48_000, root: root)
        try await invalidReference(value: 2, name: "out-of-range", root: root)
        try await invalidReference(value: .nan, name: "nonfinite", root: root)
        try await simultaneousSpeech(root: root)
        try await stopTail(root: root)
        try await cancelIsolation(root: root)
        try originalTracksPersist(root: root)
        try originalTracksPreservedOnArchiveFailure(root: root)
        print("Mac echo integration: 21 synthetic checks passed; no microphone, model, or API permission used. These checks do not establish hardware AEC effectiveness.")
    }

    static func hostNow() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    static func buffer(rate: Double, channels: AVAudioChannelCount = 1,
                       start: Int, count: Int, value: (Double) -> Float) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                        channels: channels, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let data = buffer.floatChannelData else {
            throw HarnessFailure.assertion("synthetic buffer allocation")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for index in 0..<count { data[channel][index] = value(Double(start + index) / rate) }
        }
        return buffer
    }

    @MainActor
    private static func processor(name: String, root: URL, epoch: Double, collector: Collector,
                                  clock: TestClock? = nil) throws -> MeetingEchoProcessor {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try MeetingEchoProcessor(
            directory: directory, epoch: epoch,
            onOutput: { pcm, time in collector.append(pcm, at: time) },
            onStatus: { collector.statuses.append($0) },
            monotonicNow: { clock?.now() ?? ProcessInfo.processInfo.systemUptime }
        )
    }

    @MainActor
    private static func verifyFile(_ result: MeetingEchoProcessor.Result, collector: Collector,
                           expected: Int, name: String) throws {
        try require(result.failure == nil, "\(name): \(result.failure ?? "")")
        guard let url = result.url else { throw HarnessFailure.assertion("\(name): missing CAF") }
        let file = try AVAudioFile(forReading: url)
        try require(file.length == result.frameCount,
                    "\(name): CAF/count disagreement; actual=\(file.length), written=\(result.frameCount)")
        try require(abs(Int(file.length) - expected) <= 8,
                    "\(name): resampling lost duration; actual=\(file.length), expected=\(expected)±8")
        try require(collector.samples.count == Int(result.frameCount),
                    "\(name): finish returned before live delivery; actual=\(collector.samples.count), written=\(result.frameCount)")
        try require(file.processingFormat.sampleRate == 16_000, "\(name): target rate")
        try require(file.processingFormat.channelCount == 1, "\(name): target channels")
        for pair in zip(collector.starts, collector.starts.dropFirst()) {
            try require(pair.1 >= pair.0, "\(name): nonmonotonic source timeline")
        }
    }

    @MainActor
    static func conversionWithoutReference(rate: Int, chunk: Int, root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let name = "no-reference-\(rate)"
        let processor = try processor(name: name, root: root, epoch: epoch, collector: collector)
        let total = rate * 2
        for start in stride(from: 0, to: total, by: chunk) {
            let count = min(chunk, total - start)
            let pcm = try buffer(rate: Double(rate), start: start, count: count) { _ in 0.12 }
            processor.appendMicrophone(pcm, hostTime: epoch + Double(start) / Double(rate))
        }
        let result = await processor.finish()
        try verifyFile(result, collector: collector, expected: 32_000, name: name)
        let interior = collector.samples.dropFirst(200).dropLast(200)
        try require(!interior.isEmpty, "\(name): no output")
        try require(interior.allSatisfy { abs($0 - 0.12) < 0.005 }, "\(name): original near voice changed")
        try require(collector.statuses.contains { $0.hasPrefix("系统参考暂未就绪") }, "\(name): fallback not visible")
        try require(result.diagnostics.processedSamples == 0, "\(name): pass-through marked processed")
        try require(result.diagnostics.passthroughSamples == result.frameCount, "\(name): pass-through count")
    }

    @MainActor
    static func continuousReference(referenceRate: Int, microphoneRate: Int, root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let name = "continuous-\(referenceRate)-\(microphoneRate)"
        let processor = try processor(name: name, root: root, epoch: epoch, collector: collector)
        let referenceTotal = referenceRate * 2
        let microphoneTotal = microphoneRate * 2
        let referenceChunk = referenceRate == 48_000 ? 1_024 : 2_048
        let microphoneChunk = microphoneRate == 48_000 ? 1_024 : 2_048
        for start in stride(from: 0, to: referenceTotal, by: referenceChunk) {
            let pcm = try buffer(rate: Double(referenceRate), channels: 2, start: start,
                                 count: min(referenceChunk, referenceTotal - start)) {
                Float(0.16 * sin(2 * .pi * 310 * $0))
            }
            processor.appendReference(pcm, hostTime: epoch + Double(start) / Double(referenceRate))
        }
        for start in stride(from: 0, to: microphoneTotal, by: microphoneChunk) {
            let pcm = try buffer(rate: Double(microphoneRate), start: start,
                                 count: min(microphoneChunk, microphoneTotal - start)) {
                Float(0.06 * sin(2 * .pi * 710 * $0) + 0.05 * sin(2 * .pi * 310 * ($0 - 0.03)))
            }
            processor.appendMicrophone(pcm, hostTime: epoch + Double(start) / Double(microphoneRate))
        }
        let result = await processor.finish()
        try verifyFile(result, collector: collector, expected: 32_000, name: name)
        try require(collector.statuses.contains { $0.hasPrefix("回声处理中") }, "\(name): no reference matched")
        try require(!collector.statuses.contains { $0.hasPrefix("系统参考暂未就绪") },
                    "\(name): continuous resampling created a reference hole")
        try require(result.missingReferenceSamples == 0,
                    "\(name): frame-internal reference holes bypassed cancellation")
        try require(abs(Int(result.referenceSamplesMatched) - 32_000) <= 8,
                    "\(name): reference did not cover the converted microphone")
        try require(collector.samples.allSatisfy(\.isFinite), "\(name): nonfinite output")
    }

    @MainActor
    private static func referenceCumulativeDrift(root: URL) async throws {
        // Each neighbor differs by only one 16kHz sample (0.0625ms), which
        // satisfies the 2ms adjacent-packet check while drift accumulates.
        for (packets, expectedMaximum, expectedReanchors) in [(81, 80, 0), (82, 81, 1), (164, 81, 2)] {
            let collector = Collector()
            let epoch = hostNow()
            let name = "reference-drift-\(packets)"
            let processor = try processor(name: name, root: root, epoch: epoch, collector: collector)
            for index in 0..<packets {
                let pcm = try buffer(rate: 16_000, start: index * 320, count: 320) {
                    Float(0.12 * sin(2 * .pi * 310 * $0))
                }
                processor.appendReference(pcm, hostTime: epoch + Double(index * 321) / 16_000)
            }
            let result = await processor.finish()
            try require(result.failure == nil, "\(name): reference-only processing failed")
            try require(result.diagnostics.referenceMaximumContinuousDriftFrames == Int64(expectedMaximum),
                        "\(name): cumulative timestamp drift not measured")
            try require(result.diagnostics.referenceDriftReanchors == Int64(expectedReanchors),
                        "\(name): 80-frame bound or repeated reanchoring is incorrect")
            guard let resets = result.diagnostics.filterResetReasonCounts else {
                throw HarnessFailure.assertion("\(name): missing reset diagnostics")
            }
            try require(resets.referenceDiscontinuity == 1, "\(name): adjacent packets were misclassified as gaps")
            try require(resets.referenceDrift == Int64(expectedReanchors), "\(name): drift reset classification")
            try require(result.diagnostics.filterResets == Int64(1 + expectedReanchors),
                        "\(name): filter did not reset exactly once per reanchor")
            diagnostic("\(name) maximumDriftFrames=\(expectedMaximum) driftReanchors=\(expectedReanchors)")
        }
    }

    private enum AdaptationReset: String {
        case missingReference, invalidReference, invalidMicrophone, referenceFormat
    }

    @MainActor
    private static func adaptationAfterReset(_ kind: AdaptationReset, root: URL) async throws {
        let collector = Collector()
        let clock = TestClock()
        let epoch = hostNow()
        let name = "adaptation-reset-\(kind.rawValue)"
        let processor = try processor(name: name, root: root, epoch: epoch, collector: collector, clock: clock)
        let packetSamples = 640
        let initialSamples = 64_000
        let resumedSamples = 16_000

        func appendPair(start: Int, referenceChannels: AVAudioChannelCount = 1,
                        invalidReference: Bool = false, invalidMicrophone: Bool = false,
                        omitReference: Bool = false) throws {
            if !omitReference {
                let reference = try buffer(rate: 16_000, channels: referenceChannels,
                                           start: start, count: packetSamples) {
                    invalidReference ? 2 : Float(0.12 * sin(2 * .pi * 310 * $0))
                }
                processor.appendReference(reference, hostTime: epoch + Double(start) / 16_000)
            }
            let microphone = try buffer(rate: 16_000, start: start, count: packetSamples) {
                invalidMicrophone ? 2 : Float(0.08 * sin(2 * .pi * 710 * $0))
            }
            processor.appendMicrophone(microphone, hostTime: epoch + Double(start) / 16_000)
        }

        for start in stride(from: 0, to: initialSamples, by: packetSamples) {
            clock.advance(to: Double(start) / 16_000)
            try appendPair(start: start)
            await processor.synchronize()
        }
        try require(collector.statuses.contains { $0.contains("正在适应声音") }, "\(name): initial history hint missing")
        try require(collector.statuses.last?.hasPrefix("回声处理中 ·") == true,
                    "\(name): uninterrupted processing never left the initial history hint")
        collector.statuses.removeAll()

        clock.advance(to: 4)
        try appendPair(
            start: initialSamples,
            referenceChannels: kind == .referenceFormat ? 2 : 1,
            invalidReference: kind == .invalidReference,
            invalidMicrophone: kind == .invalidMicrophone,
            omitReference: kind == .missingReference
        )
        await processor.synchronize()
        if kind == .missingReference {
            clock.advance(to: 4.25)
            await processor.synchronize()
        }
        let resumedStart = initialSamples + packetSamples
        for offset in stride(from: 0, to: resumedSamples, by: packetSamples) {
            clock.advance(to: 4.5 + Double(offset) / 16_000)
            try appendPair(start: resumedStart + offset)
            await processor.synchronize()
        }
        let result = await processor.finish()
        try verifyFile(result, collector: collector,
                       expected: initialSamples + packetSamples + resumedSamples, name: name)
        try require(result.diagnostics.processedSamples > 48_000, "\(name): baseline processing was not exercised")
        guard let continuous = result.diagnostics.continuousProcessedSamples,
              let resets = result.diagnostics.filterResetReasonCounts else {
            throw HarnessFailure.assertion("\(name): missing continuity diagnostics")
        }
        try require(continuous > 0 && continuous < 48_000,
                    "\(name): reset did not restart continuous-processing history")
        try require(collector.statuses.last?.contains("正在适应声音") == true,
                    "\(name): lifetime total suppressed the post-reset history hint")
        switch kind {
        case .missingReference:
            try require(resets.missingReference > 0, "\(name): missing-reference reset absent")
            try require(resets.missingReference * 320 == result.diagnostics.missingReferenceSamples,
                        "\(name): missing reference reset was counted more than once")
        case .invalidReference:
            try require(resets.invalidReference > 0, "\(name): invalid-reference reset absent")
            try require(resets.invalidReference * 320 == result.diagnostics.invalidReferenceSamples,
                        "\(name): invalid reference reset was counted more than once")
        case .invalidMicrophone:
            try require(resets.invalidMicrophone > 0, "\(name): invalid-microphone reset absent")
            try require(resets.invalidMicrophone * 320 == result.diagnostics.invalidMicrophoneSamples,
                        "\(name): invalid microphone reset was counted more than once")
        case .referenceFormat:
            try require(resets.referenceDiscontinuity >= 3,
                        "\(name): reference format changes did not reset filter history")
        }
        let resetTotal = resets.microphoneDiscontinuity + resets.referenceDiscontinuity
            + resets.referenceDrift + resets.missingReference + resets.invalidMicrophone
            + resets.invalidReference + resets.processorFailure
        try require(resetTotal == result.diagnostics.filterResets, "\(name): reset-reason counts disagree with total")
        let encoded = try JSONEncoder().encode(result.diagnostics)
        if kind == .missingReference {
            guard var legacy = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  let reasonFields = legacy["filterResetReasonCounts"] as? [String: Any] else {
                throw HarnessFailure.assertion("\(name): reset diagnostics were not encoded")
            }
            let allowedReasons: Set<String> = [
                "microphoneDiscontinuity", "referenceDiscontinuity", "referenceDrift",
                "missingReference", "invalidMicrophone", "invalidReference", "processorFailure"
            ]
            try require(Set(reasonFields.keys) == allowedReasons, "\(name): reset causes are not a fixed allowlist")
            for key in ["referenceMaximumContinuousDriftFrames", "referenceDriftReanchors",
                        "filterResetReasonCounts", "continuousProcessedSamples"] {
                legacy.removeValue(forKey: key)
            }
            let decoded = try JSONDecoder().decode(MeetingEchoProcessor.Diagnostics.self,
                from: JSONSerialization.data(withJSONObject: legacy))
            try require(decoded.filterResets == result.diagnostics.filterResets,
                        "\(name): legacy diagnostics totals changed while decoding")
            try require(decoded.referenceMaximumContinuousDriftFrames == nil
                        && decoded.referenceDriftReanchors == nil
                        && decoded.filterResetReasonCounts == nil
                        && decoded.continuousProcessedSamples == nil,
                        "\(name): archived diagnostics require the newly added fields")
        }
        diagnostic("\(name) totalProcessedSamples=\(result.diagnostics.processedSamples) continuousProcessedSamples=\(continuous) filterResets=\(resetTotal)")
    }

    @MainActor
    static func lateReference(captureAge: Double, root: URL) async throws {
        let collector = Collector()
        let clock = TestClock()
        let realStart = ProcessInfo.processInfo.systemUptime
        let epoch = hostNow() - captureAge
        let name = captureAge > 0 ? "late-capture-late-reference" : "late-reference"
        let processor = try processor(name: name, root: root, epoch: epoch, collector: collector, clock: clock)
        // More than one processing frame ensures this tests waiting even when
        // AVAudioConverter retains a small tail until EOS.
        let expected = 640
        let pcm = try buffer(rate: 16_000, start: 0, count: expected) {
            Float(0.1 * sin(2 * .pi * 400 * $0))
        }
        processor.appendMicrophone(pcm, hostTime: epoch)
        await processor.synchronize()
        try require(collector.samples.isEmpty, "\(name): skipped initial reference wait; actual=\(collector.samples.count)")
        clock.advance(to: 0.08)
        await processor.synchronize()
        diagnostic("\(name) clock=logical logicalMs=80 earlySamples=\(collector.samples.count) realElapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - realStart) * 1_000))")
        try require(collector.samples.isEmpty,
                    "\(name): capture age consumed the reference-arrival budget; actual=\(collector.samples.count), logicalMs=80")
        processor.appendReference(pcm, hostTime: epoch)
        await processor.synchronize()
        let result = await processor.finish()
        diagnostic("\(name) clock=logical logicalMs=80 finishedSamples=\(collector.samples.count) processedSamples=\(result.diagnostics.processedSamples) realElapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - realStart) * 1_000))")
        try verifyFile(result, collector: collector, expected: expected, name: name)
        try require(result.diagnostics.processedSamples == result.frameCount,
                    "\(name): late reference not used; processed=\(result.diagnostics.processedSamples), written=\(result.frameCount)")
        try require(result.missingReferenceSamples == 0, "\(name): early fallback")
        try require(collector.statuses.contains { $0.hasPrefix("回声处理中") }, "\(name): processing status")
    }

    @MainActor
    static func wholePacketDeadline(root: URL) async throws {
        let collector = Collector()
        let clock = TestClock()
        let epoch = hostNow() - 0.25
        let processor = try processor(name: "whole-packet-deadline", root: root, epoch: epoch, collector: collector, clock: clock)
        let expected = 8_000
        let frameSize = MeetingEchoProcessor.frameSize
        let pcm = try buffer(rate: 16_000, start: 0, count: expected) { _ in 0.12 }
        let realStart = ProcessInfo.processInfo.systemUptime
        processor.appendMicrophone(pcm, hostTime: epoch)
        await processor.synchronize()
        try require(collector.samples.isEmpty,
                    "whole-packet-deadline: skipped initial reference wait; actual=\(collector.samples.count)")
        clock.advance(to: 0.08)
        await processor.synchronize()
        let earlySamples = collector.samples.count
        let earlyMilliseconds = Int((ProcessInfo.processInfo.systemUptime - realStart) * 1_000)
        diagnostic("whole-packet-deadline clock=logical logicalMs=80 earlySamples=\(earlySamples) realElapsedMs=\(earlyMilliseconds)")
        try require(earlySamples == 0,
                    "whole-packet-deadline: old capture timestamp skipped waiting; actual=\(earlySamples), logicalMs=80, realElapsedMs=\(earlyMilliseconds)")
        // Live delivery emits complete 320-sample frames. AVAudioConverter can
        // retain tail samples until EOS, leaving one incomplete processing
        // frame. Require the other 24 frames promptly, then verify all 25 at
        // finish. Advance past the shared 180ms packet deadline exactly once:
        // a fresh per-frame wait would leave the remaining frames pending.
        let requiredLive = expected - frameSize
        clock.advance(to: 0.181)
        await processor.synchronize()
        let liveSamples = collector.samples.count
        let elapsedMilliseconds = Int((ProcessInfo.processInfo.systemUptime - realStart) * 1_000)
        diagnostic("whole-packet-deadline clock=logical logicalMs=181 beforeFinishSamples=\(liveSamples) requiredLive=\(requiredLive) expectedTotal=\(expected) realElapsedMs=\(elapsedMilliseconds)")
        let result = await processor.finish()
        let finishMilliseconds = Int((ProcessInfo.processInfo.systemUptime - realStart) * 1_000)
        diagnostic("whole-packet-deadline clock=logical logicalMs=181 finishedSamples=\(collector.samples.count) writtenSamples=\(result.frameCount) deliveredByFinish=\(collector.samples.count - liveSamples) passthroughSamples=\(result.diagnostics.passthroughSamples) realElapsedMs=\(finishMilliseconds)")
        try require(liveSamples >= requiredLive && liveSamples <= expected && liveSamples % frameSize == 0,
                    "whole-packet-deadline: complete frames unavailable after shared deadline; actual=\(liveSamples), required=\(requiredLive)...\(expected), logicalMs=181, realElapsedMs=\(elapsedMilliseconds)")
        try verifyFile(result, collector: collector, expected: expected, name: "whole-packet-deadline")
        try require(result.diagnostics.passthroughSamples == result.frameCount,
                    "whole-packet-deadline: fail-open count; actual=\(result.diagnostics.passthroughSamples), written=\(result.frameCount)")
        try require(collector.samples.allSatisfy { abs($0 - 0.12) < 0.0001 },
                    "whole-packet-deadline: local voice was muted")
    }

    @MainActor
    static func largePacketConversion(rate: Int, root: URL) async throws {
        let collector = Collector()
        let clock = TestClock()
        let epoch = hostNow()
        let name = "large-packet-\(rate)"
        let processor = try processor(name: name, root: root, epoch: epoch, collector: collector, clock: clock)
        let expected = 8_000
        let requiredLive = expected - MeetingEchoProcessor.frameSize
        let pcm = try buffer(rate: Double(rate), start: 0, count: rate / 2) { _ in 0.12 }
        processor.appendMicrophone(pcm, hostTime: epoch)
        await processor.synchronize()
        try require(collector.samples.isEmpty,
                    "\(name): skipped reference wait; actual=\(collector.samples.count)")
        clock.advance(to: 0.181)
        await processor.synchronize()
        let liveSamples = collector.samples.count
        let result = await processor.finish()
        diagnostic("\(name) clock=logical logicalMs=181 beforeFinishSamples=\(liveSamples) requiredLive=\(requiredLive) finishedSamples=\(collector.samples.count) deliveredByFinish=\(collector.samples.count - liveSamples)")
        try require(liveSamples >= requiredLive && liveSamples <= expected
                    && liveSamples % MeetingEchoProcessor.frameSize == 0,
                    "\(name): complete frames unavailable after shared deadline; actual=\(liveSamples), required=\(requiredLive)...\(expected), logicalMs=181")
        try verifyFile(result, collector: collector, expected: expected, name: name)
        try require(result.diagnostics.passthroughSamples == result.frameCount,
                    "\(name): pass-through count")
        let interior = collector.samples.dropFirst(200).dropLast(200)
        try require(!interior.isEmpty && interior.allSatisfy { abs($0 - 0.12) < 0.005 },
                    "\(name): original near voice changed")
    }

    @MainActor
    static func invalidReference(value: Float, name: String, root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let processor = try processor(name: name, root: root, epoch: epoch, collector: collector)
        let ref = try buffer(rate: 16_000, start: 0, count: 320) { _ in value }
        let mic = try buffer(rate: 16_000, start: 0, count: 320) { _ in 0.12 }
        processor.appendReference(ref, hostTime: epoch)
        processor.appendMicrophone(mic, hostTime: epoch)
        let result = await processor.finish()
        try verifyFile(result, collector: collector, expected: 320, name: name)
        try require(result.referenceSamplesMatched == 320, "\(name): reference coverage")
        try require(result.diagnostics.processedSamples == 0, "\(name): invalid reference marked processed")
        try require(result.diagnostics.invalidReferenceSamples == 320, "\(name): invalid-reference count")
        try require(collector.statuses.contains { $0.hasPrefix("音频数据异常") }, "\(name): false active status")
        try require(collector.samples.allSatisfy { abs($0 - 0.12) < 0.0001 }, "\(name): fail-open changed microphone")
        _ = try JSONEncoder().encode(result.diagnostics)
    }

    @MainActor
    static func simultaneousSpeech(root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let processor = try processor(name: "double-talk-from-start", root: root, epoch: epoch, collector: collector)
        let rate = 16_000
        func far(_ time: Double) -> Float {
            guard time >= 0 else { return 0 }
            return Float(0.19 * sin(2 * .pi * 310 * time)
                         + 0.09 * sin(2 * .pi * 470 * time)
                         + 0.04 * sin(2 * .pi * 610 * time))
        }
        func near(_ time: Double) -> Float {
            Float(0.020 * sin(2 * .pi * 870 * time) + 0.011 * sin(2 * .pi * 1_090 * time))
        }
        for start in stride(from: 0, to: rate * 3, by: 320) {
            let ref = try buffer(rate: Double(rate), start: start, count: 320, value: far)
            let mic = try buffer(rate: Double(rate), start: start, count: 320) {
                0.38 * far($0 - 0.08) + near($0)
            }
            processor.appendReference(ref, hostTime: epoch + Double(start) / Double(rate))
            processor.appendMicrophone(mic, hostTime: epoch + Double(start) / Double(rate))
        }
        let result = await processor.finish()
        try verifyFile(result, collector: collector, expected: rate * 3, name: "double-talk-from-start")
        try require(result.diagnostics.processedSamples == Int64(rate * 3), "double-talk-from-start: filtering gaps")
        let local = (0..<rate).map { Double(near(Double($0) / Double(rate))) }
        let inputEnergy = local.reduce(0) { $0 + $1 * $1 }
        let projection = zip(collector.samples.prefix(rate), local).reduce(0.0) {
            $0 + Double($1.0) * $1.1
        } / inputEnergy
        try require(projection > 0.75, "double-talk-from-start: weak local speech lost during convergence")
        try require(collector.samples.allSatisfy(\.isFinite), "double-talk-from-start: nonfinite output")
    }

    @MainActor
    static func stopTail(root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let processor = try processor(name: "stop-tail", root: root, epoch: epoch, collector: collector)
        let pcm = try buffer(rate: 16_000, start: 0, count: 333) { _ in 0.23 }
        processor.appendMicrophone(pcm, hostTime: epoch)
        let result = await processor.finish()
        try verifyFile(result, collector: collector, expected: 333, name: "stop-tail")
        try require(collector.samples.count == 333, "stop-tail: tail or padded samples persisted")
        try require(collector.samples.suffix(13).allSatisfy { abs($0 - 0.23) < 0.0001 }, "stop-tail: near voice lost")
        let after = try buffer(rate: 16_000, start: 333, count: 320) { _ in 0.5 }
        processor.appendMicrophone(after, hostTime: epoch + 333.0 / 16_000)
        await processor.synchronize()
        let again = await processor.finish()
        try require(again.frameCount == 333 && collector.samples.count == 333, "stop-tail: post-finish data accepted")
    }

    @MainActor
    static func cancelIsolation(root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let processor = try processor(name: "cancel", root: root, epoch: epoch, collector: collector)
        let pcm = try buffer(rate: 16_000, start: 0, count: 100) { _ in 0.2 }
        processor.appendMicrophone(pcm, hostTime: epoch)
        await processor.cancel()
        processor.appendMicrophone(pcm, hostTime: epoch)
        processor.appendReference(pcm, hostTime: epoch)
        await processor.synchronize()
        let result = await processor.finish()
        try require(result.url == nil && collector.samples.isEmpty, "cancel: late output escaped generation")
    }

    static func originalTracksPersist(root: URL) throws {
        let sessionID = UUID()
        let recordings = root.appendingPathComponent("archive-success", isDirectory: true)
        let session = recordings.appendingPathComponent(".meeting-\(sessionID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let microphone = session.appendingPathComponent("recording-synthetic.caf")
        let system = session.appendingPathComponent("system.caf")
        let cleaned = session.appendingPathComponent("microphone-cleaned.caf")
        for (url, value) in [(microphone, Float(0.12)), (system, Float(0.23)), (cleaned, Float(0.03))] {
            let pcm = try buffer(rate: 16_000, start: 0, count: 320) { _ in value }
            let audio = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            try audio.write(from: pcm)
        }
        let microphoneBytes = try Data(contentsOf: microphone)
        let systemBytes = try Data(contentsOf: system)
        let tracks = [
            OriginalMeetingAudioArchive.Track(role: .microphone, url: microphone, firstOffsetSeconds: 0.03),
            OriginalMeetingAudioArchive.Track(role: .system, url: system, firstOffsetSeconds: 0),
            OriginalMeetingAudioArchive.Track(role: .cleanedMicrophone, url: cleaned, firstOffsetSeconds: 0.03)
        ]
        let metadata = OriginalMeetingAudioArchive.Metadata(
            capturedAt: Date(timeIntervalSince1970: 0), recordingSource: "both", tracks: tracks, echo: nil
        )
        let archived = try OriginalMeetingAudioArchive.preserve(
            sessionDirectory: session, in: recordings, sessionID: sessionID,
            microphoneURL: microphone, metadata: metadata
        )
        try require(!FileManager.default.fileExists(atPath: session.path), "archive: old session still present")
        try require(archived.lastPathComponent == sessionID.uuidString, "archive: wrong session directory")
        let archivedMicrophone = try Data(contentsOf: archived.appendingPathComponent("microphone-original.caf"))
        let archivedSystem = try Data(contentsOf: archived.appendingPathComponent("system.caf"))
        try require(archivedMicrophone == microphoneBytes,
                    "archive: original microphone discarded or modified")
        try require(archivedSystem == systemBytes,
                    "archive: original system track modified")
        try require(FileManager.default.fileExists(atPath: archived.appendingPathComponent("microphone-cleaned.caf").path),
                    "archive: processed track missing")
        let data = try Data(contentsOf: archived.appendingPathComponent("diagnostics.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(OriginalMeetingAudioArchive.Metadata.self, from: data)
        try require(decoded.tracks.count == 3 && decoded.schemaVersion == 1, "archive: missing format diagnostics")
        try require(decoded.tracks[0].samples == 320 && decoded.tracks[0].sampleRate == 16_000,
                    "archive: original format metadata")
    }

    static func originalTracksPreservedOnArchiveFailure(root: URL) throws {
        let sessionID = UUID()
        let recordings = root.appendingPathComponent("archive-failure", isDirectory: true)
        let session = recordings.appendingPathComponent(".meeting-\(sessionID.uuidString)", isDirectory: true)
        let existing = recordings.appendingPathComponent("Originals/\(sessionID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let microphone = session.appendingPathComponent("recording-synthetic.caf")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: microphone)
        let metadata = OriginalMeetingAudioArchive.Metadata(
            capturedAt: Date(timeIntervalSince1970: 0), recordingSource: "microphone", tracks: [], echo: nil
        )
        var failed = false
        do {
            _ = try OriginalMeetingAudioArchive.preserve(
                sessionDirectory: session, in: recordings, sessionID: sessionID,
                microphoneURL: microphone, metadata: metadata
            )
        } catch { failed = true }
        try require(failed, "archive-failure: existing session overwritten")
        let preservedBytes = try Data(contentsOf: microphone)
        try require(preservedBytes == bytes, "archive-failure: originals deleted on error")

        // Also fail after the original microphone has been renamed, proving
        // that a later metadata-write error keeps the recoverable session.
        let nextID = UUID()
        let nextSession = recordings.appendingPathComponent(".meeting-\(nextID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nextSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: nextSession.appendingPathComponent("diagnostics.json", isDirectory: true),
            withIntermediateDirectories: true
        )
        let nextMicrophone = nextSession.appendingPathComponent("recording-synthetic.caf")
        try bytes.write(to: nextMicrophone)
        failed = false
        do {
            _ = try OriginalMeetingAudioArchive.preserve(
                sessionDirectory: nextSession, in: recordings, sessionID: nextID,
                microphoneURL: nextMicrophone, metadata: metadata
            )
        } catch { failed = true }
        try require(failed, "archive-failure: metadata collision not reported")
        let renamedBytes = try Data(contentsOf: nextSession.appendingPathComponent("microphone-original.caf"))
        try require(renamedBytes == bytes, "archive-failure: renamed original deleted on later error")
    }
}
