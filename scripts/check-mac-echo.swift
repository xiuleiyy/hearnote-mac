import AVFoundation
import CoreMedia
import Foundation

private enum HarnessFailure: Error { case assertion(String) }

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw HarnessFailure.assertion(message) }
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
        try await lateReference(root: root)
        try await stopTail(root: root)
        try await cancelIsolation(root: root)
        print("Mac echo integration: 7 synthetic checks passed; no microphone, model, or API permission used.")
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
    static func processor(name: String, root: URL, epoch: Double, collector: Collector) throws -> MeetingEchoProcessor {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try MeetingEchoProcessor(
            directory: directory, epoch: epoch,
            onOutput: { pcm, time in collector.append(pcm, at: time) },
            onStatus: { collector.statuses.append($0) }
        )
    }

    @MainActor
    static func verifyFile(_ result: MeetingEchoProcessor.Result, collector: Collector,
                           expected: Int, name: String) throws {
        try require(result.failure == nil, "\(name): \(result.failure ?? "")")
        guard let url = result.url else { throw HarnessFailure.assertion("\(name): missing CAF") }
        let file = try AVAudioFile(forReading: url)
        try require(file.length == result.frameCount, "\(name): CAF/count disagreement")
        try require(abs(Int(file.length) - expected) <= 8, "\(name): resampling lost duration")
        try require(collector.samples.count == Int(result.frameCount), "\(name): finish returned before live delivery")
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
        try require(collector.statuses.contains("系统参考暂未就绪，麦克风原音保留"), "\(name): fallback not visible")
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
        try require(collector.statuses.contains("外放回声消除已开启"), "\(name): no reference matched")
        try require(!collector.statuses.contains("系统参考暂未就绪，麦克风原音保留"),
                    "\(name): continuous resampling created a reference hole")
        try require(result.missingReferenceSamples == 0,
                    "\(name): frame-internal reference holes bypassed cancellation")
        try require(abs(Int(result.referenceSamplesMatched) - 32_000) <= 8,
                    "\(name): reference did not cover the converted microphone")
        try require(collector.samples.allSatisfy(\.isFinite), "\(name): nonfinite output")
    }

    @MainActor
    static func lateReference(root: URL) async throws {
        let collector = Collector()
        let epoch = hostNow()
        let processor = try processor(name: "late-reference", root: root, epoch: epoch, collector: collector)
        let pcm = try buffer(rate: 16_000, start: 0, count: 320) {
            Float(0.1 * sin(2 * .pi * 400 * $0))
        }
        processor.appendMicrophone(pcm, hostTime: epoch)
        // Leave scheduling margin below the real-time 180ms fallback deadline.
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(collector.samples.isEmpty, "late-reference: microphone processed before bounded wait")
        processor.appendReference(pcm, hostTime: epoch)
        let result = await processor.finish()
        try verifyFile(result, collector: collector, expected: 320, name: "late-reference")
        try require(collector.statuses.contains("外放回声消除已开启"), "late-reference: late reference not used")
        try require(!collector.statuses.contains("系统参考暂未就绪，麦克风原音保留"), "late-reference: early fallback")
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
        let result = await processor.finish()
        try require(result.url == nil && collector.samples.isEmpty, "cancel: late output escaped generation")
    }
}
