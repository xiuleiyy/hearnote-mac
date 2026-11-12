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
        try await lateReference(captureAge: 0, root: root)
        try await lateReference(captureAge: 0.25, root: root)
        try await wholePacketDeadline(root: root)
        try await invalidReference(value: 2, name: "out-of-range", root: root)
        try await invalidReference(value: .nan, name: "nonfinite", root: root)
        try await simultaneousSpeech(root: root)
        try await stopTail(root: root)
        try await cancelIsolation(root: root)
        try originalTracksPersist(root: root)
        try originalTracksPreservedOnArchiveFailure(root: root)
        print("Mac echo integration: 14 synthetic checks passed; no microphone, model, or API permission used.")
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
                    "whole-packet-deadline: frame-by-frame wait accumulated; actual=\(liveSamples), required=\(requiredLive)...\(expected), logicalMs=181, realElapsedMs=\(elapsedMilliseconds)")
        try verifyFile(result, collector: collector, expected: expected, name: "whole-packet-deadline")
        try require(result.diagnostics.passthroughSamples == result.frameCount,
                    "whole-packet-deadline: fail-open count; actual=\(result.diagnostics.passthroughSamples), written=\(result.frameCount)")
        try require(collector.samples.allSatisfy { abs($0 - 0.12) < 0.0001 },
                    "whole-packet-deadline: local voice was muted")
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
