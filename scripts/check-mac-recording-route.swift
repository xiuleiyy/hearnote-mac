import AVFoundation
import Darwin
import Foundation

/// Exercises the production sink with synthetic PCM only. No engine, device,
/// permissions, Speech assets, Bedrock requests or real recording is involved.
@main
struct MacRecordingRouteCheck {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hearnote-route-synthetic-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
            guard try condition() else { throw CheckFailure(description: detail) }
            checks += 1
        }
        let stable = try format(48_000, channels: 1)

        // Saved, but not delivered, tap PCM must precede retirement's EOS tail.
        let queuedURL = directory.appendingPathComponent("queued.caf")
        let queued = try RecordingSink(url: queuedURL, format: stable)
        let old = UUID()
        try queued.activateInput(old, format: stable)
        for index in 0..<4 {
            let pcm = try buffer(stable, offset: index * 127, frames: 127)
            queued.consume(pcm, hostTime: 20 + Double(index * 127) / 48_000, input: old) {}
        }
        let retirement = try queued.retireInput(old)
        try expect(retirement.count == 4, "retirement drains earlier queued tap PCM")
        try expect(retirement.allSatisfy { $0.error == nil && $0.inputID == old }, "retired results retain original input lease")
        try expect(zip(retirement, retirement.dropFirst()).allSatisfy { $0.0.elapsed < $0.1.elapsed },
                   "queued results precede tail in increasing saved timeline")
        try expect(queued.takePendingResults().isEmpty, "late queued notifications cannot deliver PCM twice")
        queued.consume(try buffer(stable, offset: 0, frames: 127), hostTime: 30, input: old) {}
        try expect(queued.takePendingResults().isEmpty, "retired tap cannot append to same file")
        try expect(try queued.close().isEmpty, "Stop during recovery closes sink with no engine")
        try expect(try read(queuedURL).count == 508, "Stop during recovery preserves prior PCM")
        var rejectedClosed = false
        do { try queued.activateInput(UUID(), format: stable) }
        catch { rejectedClosed = true }
        try expect(rejectedClosed, "closed recording cannot be revived by a later retry")
        queued.consume(try buffer(stable, offset: 0, frames: 127), hostTime: 40, input: old) {}
        try expect(queued.takePendingResults().isEmpty, "closed sink rejects late native callbacks")

        // One output file, fixed PCM for file/ASR/echo, native rates and channels
        // vary and the route gap remains on the original host-clock timeline.
        let mixedURL = directory.appendingPathComponent("mixed-routes.caf")
        let mixed = try RecordingSink(url: mixedURL, format: stable)
        var deliveries: [RecordingSink.Result] = []
        var expectedFrames = 0
        let routes: [(Double, AVAudioChannelCount, Int, Double)] = [
            (48_000, 1, 4_801, 100),
            (16_000, 1, 1_603, 100.25),
            (44_100, 2, 4_419, 100.50),
            (24_000, 1, 2_403, 100.75),
            (8_000, 1, 803, 101.0)
        ]
        for (rate, channels, frames, hostTime) in routes {
            let source = try format(rate, channels: channels)
            let id = UUID()
            try mixed.activateInput(id, format: source)
            var offset = 0
            while offset < frames {
                let count = min(127, frames - offset)
                mixed.consume(try buffer(source, offset: offset, frames: count),
                              hostTime: hostTime + Double(offset) / rate, input: id) {}
                offset += count
            }
            let retiredResults = try mixed.retireInput(id)
            deliveries += retiredResults
            expectedFrames = Int(((hostTime - 100) * 48_000).rounded())
                + Int((Double(frames) * 48_000 / rate).rounded())
            let deliveredFrames = retiredResults.compactMap(\.buffer).reduce(0) { $0 + Int($1.frameLength) }
            print("Mac route epoch: sourceRate=\(rate) sourceChannels=\(channels) sourceFrames=\(frames) targetRate=\(stable.sampleRate) targetChannels=\(stable.channelCount) inputStartHost=\(hostTime) deliveredFrames=\(deliveredFrames) firstDeliveredHost=\(retiredResults.first?.hostTime ?? -1) lastDeliveredHost=\(retiredResults.last?.hostTime ?? -1) lastElapsed=\(retiredResults.last?.elapsed ?? -1) expectedSavedFrames=\(expectedFrames)")
        }
        deliveries += try mixed.close()
        try expect(deliveries.allSatisfy { $0.error == nil }, "route conversion and EOS retain all tails")
        try expect(deliveries.allSatisfy { $0.buffer?.format == stable }, "file, ASR and echo all receive stable PCM")
        try expect(zip(deliveries, deliveries.dropFirst()).allSatisfy { $0.0.hostTime < $0.1.hostTime },
                   "format changes keep one increasing host timeline")
        let mixedSamples = try read(mixedURL)
        let readFormat = try AVAudioFile(forReading: mixedURL).processingFormat
        print("Mac route file: actualFrames=\(mixedSamples.count) expectedFrames=\(expectedFrames) firstHost=\(mixed.capturedStartHostTime ?? -1) lastElapsed=\(deliveries.last?.elapsed ?? -1) actualRate=\(readFormat.sampleRate) actualChannels=\(readFormat.channelCount)")
        fflush(stdout)
        try expect(mixedSamples.count == expectedFrames,
                   "saved route gaps and format durations match host timeline actual=\(mixedSamples.count) expected=\(expectedFrames) targetRate=\(stable.sampleRate) targetChannels=\(stable.channelCount)")
        try expect(mixedSamples[5_000..<11_500].allSatisfy { $0 == 0 }, "route gap is stored as silence at the original offset")
        try expect(mixedSamples[0..<4_800].contains { abs($0) > 0.0001 }, "earlier microphone PCM remains readable")
        try expect(mixedSamples.suffix(160).contains { abs($0) > 0.0001 }, "final short native tail survives EOS")

        // Fractional conversion must not discard a sample produced ahead of the
        // latest input duration. Different chunking must reproduce whole-input
        // conversion, including weak voice and a near-tail impulse.
        for target in [stable, try format(16_000, channels: 1), try format(48_000, channels: 2)] {
            for rate in [8_000.0, 16_000.0, 24_000.0, 44_100.0, 48_000.0] {
                for channels: AVAudioChannelCount in [1, 2] {
                    let source = try format(rate, channels: channels)
                    for frames in [160, 161, 1_337] {
                        let whole = try converted(source: source, frames: frames, chunk: frames,
                                                  directory: directory, stable: target)
                        let split = try converted(source: source, frames: frames, chunk: 37,
                                                  directory: directory, stable: target)
                        let expected = Int((Double(frames) * target.sampleRate / rate).rounded())
                        let label = "\(rate)/\(channels)/\(frames)→\(target.sampleRate)/\(target.channelCount)"
                        try expect(whole.count == expected && split.count == expected,
                                   "whole/chunk exact converted frame count: \(label)")
                        let maxError = zip(whole, split).map { abs(Double($0.0) - Double($0.1)) }.max() ?? 0
                        try expect(maxError < 0.000_002, "chunk-independent fractional conversion and tail: \(label)")
                        let energy = whole.reduce(0.0) { $0 + Double($1) * Double($1) }
                        let projection = zip(whole, split).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
                        try expect(energy > 0 && projection / energy > 0.99,
                                   "weak tone/near-tail impulse amplitude retained: \(label)")
                        try expect(split.suffix(min(160, split.count)).contains { abs($0) > 0.000_01 },
                                   "last converted samples are retained: \(label)")
                    }
                }
            }
        }

        // A native format change may arrive before its configuration notification.
        let earlyURL = directory.appendingPathComponent("format-before-notification.caf")
        let early = try RecordingSink(url: earlyURL, format: stable)
        let lease = UUID()
        try early.activateInput(lease, format: stable)
        early.consume(try buffer(stable, offset: 0, frames: 480), hostTime: 200, input: lease) {}
        let changed = try format(16_000, channels: 1)
        early.consume(try buffer(changed, offset: 0, frames: 161), hostTime: 200.01, input: lease) {}
        let earlyResults = try early.close()
        try expect(earlyResults.allSatisfy { $0.error == nil }, "format-before-notification remains nonfatal")
        try expect(try read(earlyURL).count == 963, "format-before-notification preserves both epochs")
        try expect(early.takePendingResults().isEmpty, "Stop drains queued PCM exactly once")
        print("Mac recording route synthetic checks: \(checks) passed; no microphone, models or network used.")
    }

    private static func format(_ rate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                        channels: channels, interleaved: false) else {
            throw CheckFailure(description: "synthetic format allocation")
        }
        return format
    }

    private static func buffer(_ format: AVAudioFormat, offset: Int, frames: Int,
                               impulseAt: Int = 150) throws -> AVAudioPCMBuffer {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = pcm.floatChannelData else {
            throw CheckFailure(description: "synthetic buffer allocation")
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for index in 0..<frames {
                let time = Double(offset + index) / format.sampleRate
                var value = 0.0002 * sin(2 * .pi * 611 * time)
                    + 0.0001 * sin(2 * .pi * 143 * time)
                if offset + index == impulseAt { value += 0.002 }
                channels[channel][index] = Float(value)
            }
        }
        return pcm
    }

    private static func converted(source: AVAudioFormat, frames: Int, chunk: Int,
                                  directory: URL, stable: AVAudioFormat) throws -> [Float] {
        let url = directory.appendingPathComponent("conversion-\(UUID().uuidString).caf")
        let sink = try RecordingSink(url: url, format: stable)
        let id = UUID()
        try sink.activateInput(id, format: source)
        var offset = 0
        while offset < frames {
            let count = min(chunk, frames - offset)
            sink.consume(try buffer(source, offset: offset, frames: count, impulseAt: frames - 11),
                         hostTime: 10 + Double(offset) / source.sampleRate, input: id) {}
            offset += count
        }
        let deliveries = try sink.close()
        if let error = deliveries.compactMap(\.error).first { throw error }
        let savedChannels = try readChannels(url)
        guard savedChannels.count == Int(stable.channelCount),
              let samples = savedChannels.first,
              savedChannels.allSatisfy({ $0.count == samples.count }),
              deliveries.allSatisfy({ $0.buffer?.format == stable }) else {
            throw CheckFailure(description: "saved/delivered channel layout and frame count")
        }
        if stable.channelCount == 2 {
            let right = savedChannels[1]
            let difference = zip(samples, right).map { abs(Double($0.0) - Double($0.1)) }.max() ?? 0
            guard difference < 0.000_002,
                  right.contains(where: { abs($0) > 0.000_01 }),
                  right.suffix(min(160, right.count)).contains(where: { abs($0) > 0.000_01 }) else {
                throw CheckFailure(description: "mono/stereo conversion retains weak voice and tail in right channel")
            }
        }
        let delivered = deliveries.compactMap(\.buffer).reduce(0) { $0 + Int($1.frameLength) }
        guard delivered == samples.count else { throw CheckFailure(description: "final file versus ASR delivery length") }
        return samples
    }

    private static func read(_ url: URL) throws -> [Float] {
        guard let first = try readChannels(url).first else {
            throw CheckFailure(description: "saved channel missing")
        }
        return first
    }

    private static func readChannels(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CheckFailure(description: "saved synthetic PCM allocation")
        }
        try file.read(into: buffer)
        guard let samples = buffer.floatChannelData else { throw CheckFailure(description: "saved Float PCM") }
        return (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: samples[$0], count: Int(buffer.frameLength)))
        }
    }
}
