import AVFoundation
import CoreMedia
import Foundation
import HearNoteCore

private enum MeetingEchoError: LocalizedError {
    case invalidAudio
    var errorDescription: String? { "音频格式或时间戳无法处理" }
}

/// The original microphone and system files remain available until mixing succeeds.
/// Only the microphone's live stream and the replacement microphone track are processed.
final class MeetingEchoProcessor: @unchecked Sendable {
    struct Result: Sendable {
        let url: URL?
        let firstHostTime: Double?
        let frameCount: Int64
        let referenceSamplesMatched: Int64
        let missingReferenceSamples: Int64
        let failure: String?
    }

    private final class Packet: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let hostTime: Double
        init(_ buffer: AVAudioPCMBuffer, _ hostTime: Double) {
            self.buffer = buffer
            self.hostTime = hostTime
        }
    }

    private struct Reference {
        let start: Int64
        let samples: [Float]
        var end: Int64 { start + Int64(samples.count) }
    }

    static let sampleRate = 16_000
    static let frameSize = 320
    private let queue = DispatchQueue(label: "app.hearnote.echo", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancelled = false
    private let epoch: Double
    private let url: URL
    private let format: AVAudioFormat
    private let canceller: AcousticEchoCanceller
    private let onOutput: @MainActor @Sendable (AVAudioPCMBuffer, Double) -> Void
    private let onStatus: @MainActor @Sendable (String) -> Void
    // All state below is owned by queue.
    private var microphoneConverter: AVAudioConverter?
    private var microphoneNextFrame: Int64?
    private var microphoneExpectedHostTime: Double?
    private var referenceConverter: AVAudioConverter?
    private var referenceNextFrame: Int64?
    private var referenceExpectedHostTime: Double?
    private var references: [Reference] = []
    private var pendingMicrophone: [Float] = []
    private var pendingStart: Int64?
    private var firstWrittenFrame: Int64?
    private var writtenFrames: Int64 = 0
    private var referenceSamplesMatched: Int64 = 0
    private var missingReferenceSamples: Int64 = 0
    private var file: AVAudioFile?
    private var failure: String?
    private var finished = false
    private var result: Result?
    private var deliveryTail: Task<Void, Never>?
    private var timer: DispatchSourceTimer?
    private var lastStatus = ""
    private var lastStatusUpdate = -Double.infinity

    init(directory: URL, epoch: Double,
         onOutput: @escaping @MainActor @Sendable (AVAudioPCMBuffer, Double) -> Void,
         onStatus: @escaping @MainActor @Sendable (String) -> Void) throws {
        self.epoch = epoch
        self.onOutput = onOutput
        self.onStatus = onStatus
        url = directory.appendingPathComponent("microphone-cleaned.caf")
        guard epoch.isFinite,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Double(Self.sampleRate), channels: 1,
                                       interleaved: false) else {
            throw MeetingEchoError.invalidAudio
        }
        format = mono
        canceller = try AcousticEchoCanceller(sampleRate: Self.sampleRate,
                                             frameSize: Self.frameSize, filterLength: 4_000)
        file = try AVAudioFile(forWriting: url, settings: mono.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isCancelled, !self.finished else { return }
            self.drainMicrophone(finishing: false)
        }
        self.timer = timer
        timer.resume()
    }

    /// Called by the capture sink before its raw-file flush can finish, not by UI delivery.
    func appendMicrophone(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        let packet = Packet(buffer, hostTime)
        queue.async { [self, packet] in
            guard !isCancelled, !finished else { return }
            guard failure == nil else {
                deliver(packet)
                return
            }
            do {
                let stampedStart = try frameIndex(packet.hostTime)
                let continuous = microphoneConverter?.inputFormat == packet.buffer.format
                    && microphoneExpectedHostTime.map { abs(packet.hostTime - $0) <= 0.002 } == true
                    && microphoneNextFrame.map { abs(stampedStart - $0) <= 80 } == true
                let samples = try convertedSamples(packet.buffer, reference: false)
                let start = continuous ? (microphoneNextFrame ?? stampedStart) : stampedStart
                microphoneExpectedHostTime = packet.hostTime
                    + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
                microphoneNextFrame = start + Int64(samples.count)
                guard !samples.isEmpty else { return }
                if let pendingStart,
                   abs(start - (pendingStart + Int64(pendingMicrophone.count))) > 80 {
                    // Device gaps must not concatenate unrelated acoustic histories.
                    drainMicrophone(finishing: true)
                    guard failure == nil else { deliver(packet); return }
                    canceller.reset()
                    self.pendingStart = nil
                }
                if pendingStart == nil { pendingStart = start }
                pendingMicrophone.append(contentsOf: samples)
                drainMicrophone(finishing: false)
            } catch {
                degrade(error)
                deliver(packet)
            }
        }
    }

    func appendReference(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        let packet = Packet(buffer, hostTime)
        queue.async { [self, packet] in
            guard !isCancelled, !finished, failure == nil else { return }
            do {
                let continuous = referenceConverter?.inputFormat == packet.buffer.format
                    && referenceExpectedHostTime.map { abs(packet.hostTime - $0) <= 0.002 } == true
                let samples = try convertedSamples(packet.buffer, reference: true)
                let stampedStart = try frameIndex(packet.hostTime)
                let start = continuous ? (referenceNextFrame ?? stampedStart) : stampedStart
                referenceExpectedHostTime = packet.hostTime
                    + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
                referenceNextFrame = start + Int64(samples.count)
                guard !samples.isEmpty else { return }
                if !continuous { canceller.reset() }
                references.append(Reference(start: start, samples: samples))
                references.sort { $0.start < $1.start }
                // Four seconds is a hard bound even if the microphone never delivers.
                let lower = start - Int64(Self.sampleRate * 4)
                references.removeAll { $0.end < lower }
                drainMicrophone(finishing: false)
            } catch {
                degrade(error)
            }
        }
    }

    /// Capture producers must already be stopped/flushed. This also awaits every live delivery.
    func finish() async -> Result {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !finished {
                    timer?.cancel()
                    timer = nil
                    if !isCancelled, failure == nil {
                        do { try flushConverters() } catch { degrade(error) }
                        drainMicrophone(finishing: true)
                    }
                    file = nil
                    finished = true
                    references.removeAll()
                    pendingMicrophone.removeAll()
                    result = Result(
                        url: !isCancelled && failure == nil && writtenFrames > 0 ? url : nil,
                        firstHostTime: firstWrittenFrame.map { epoch + Double($0) / Double(Self.sampleRate) },
                        frameCount: writtenFrames, referenceSamplesMatched: referenceSamplesMatched,
                        missingReferenceSamples: missingReferenceSamples, failure: failure
                    )
                }
                let completed = result!
                let deliveries = deliveryTail
                Task {
                    if let deliveries { await deliveries.value }
                    continuation.resume(returning: completed)
                }
            }
        }
    }

    func cancel() async {
        markCancelled()
        _ = await finish()
    }

    private func markCancelled() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    private func frameIndex(_ hostTime: Double) throws -> Int64 {
        let value = (hostTime - epoch) * Double(Self.sampleRate)
        guard value.isFinite, abs(value) < Double(Int64.max / 2) else {
            throw MeetingEchoError.invalidAudio
        }
        return Int64(value.rounded())
    }

    private func convertedSamples(_ buffer: AVAudioPCMBuffer, reference: Bool) throws -> [Float] {
        var converter = reference ? referenceConverter : microphoneConverter
        if converter?.inputFormat != buffer.format {
            guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0,
                  let next = AVAudioConverter(from: buffer.format, to: format) else {
                throw MeetingEchoError.invalidAudio
            }
            next.primeMethod = .none
            converter = next
            if reference { referenceConverter = next } else { microphoneConverter = next }
        }
        guard let converter, let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength)
                * Double(Self.sampleRate) / buffer.format.sampleRate) + 64)
        ) else { throw MeetingEchoError.invalidAudio }
        var supplied = false
        var error: NSError?
        let state = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard state != .error, error == nil, let data = output.floatChannelData?[0] else {
            if let error { throw error }
            throw MeetingEchoError.invalidAudio
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    private func referenceFrame(start: Int64, count: Int) -> [Float]? {
        var frame = [Float](repeating: 0, count: count)
        var covered = [Bool](repeating: false, count: count)
        let end = start + Int64(count)
        for reference in references where reference.end > start && reference.start < end {
            let from = max(start, reference.start)
            let to = min(end, reference.end)
            for position in from..<to {
                let destination = Int(position - start)
                frame[destination] = reference.samples[Int(position - reference.start)]
                covered[destination] = true
            }
        }
        // Resampling rounding may differ by one sample between independent sources.
        if covered.first == false, count > 1, covered[1] { frame[0] = frame[1]; covered[0] = true }
        if covered.last == false, count > 1, covered[count - 2] {
            frame[count - 1] = frame[count - 2]; covered[count - 1] = true
        }
        return covered.allSatisfy { $0 } ? frame : nil
    }

    /// The converter can retain fractional-rate filter samples after `.noDataNow`.
    /// EOS drains those samples, but never extends either stream's captured duration.
    private func converterTail(_ converter: AVAudioConverter?) throws -> [Float] {
        guard let converter else { return [] }
        var samples: [Float] = []
        for _ in 0..<4 {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600) else {
                throw MeetingEchoError.invalidAudio
            }
            var error: NSError?
            let state = converter.convert(to: output, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            guard state != .error, let channel = output.floatChannelData?[0] else {
                throw MeetingEchoError.invalidAudio
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            if state == .endOfStream || output.frameLength == 0 { return samples }
        }
        throw MeetingEchoError.invalidAudio
    }

    private func flushConverters() throws {
        let referenceTail = try converterTail(referenceConverter)
        if let start = referenceNextFrame, let endTime = referenceExpectedHostTime {
            let remaining = max(0, try frameIndex(endTime) - start)
            let samples = Array(referenceTail.prefix(Int(remaining)))
            if !samples.isEmpty { references.append(Reference(start: start, samples: samples)) }
        }
        let microphoneTail = try converterTail(microphoneConverter)
        if let start = microphoneNextFrame, let endTime = microphoneExpectedHostTime {
            let remaining = max(0, try frameIndex(endTime) - start)
            let samples = Array(microphoneTail.prefix(Int(remaining)))
            if !samples.isEmpty {
                if pendingStart == nil { pendingStart = start }
                pendingMicrophone.append(contentsOf: samples)
            }
        }
    }

    private func drainMicrophone(finishing: Bool) {
        guard failure == nil else { return }
        while let start = pendingStart, !pendingMicrophone.isEmpty {
            if pendingMicrophone.count < Self.frameSize && !finishing { return }
            let count = min(Self.frameSize, pendingMicrophone.count)
            let reference = referenceFrame(start: start, count: count)
            let hostTime = epoch + Double(start) / Double(Self.sampleRate)
            let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            // A late reference may arrive before its own buffered microphone is processed.
            // After 180ms, or when stopping, preserve the microphone instead of muting it.
            if reference == nil, !finishing, now - hostTime < 0.18,
               pendingMicrophone.count < Self.sampleRate { return }
            var microphone = Array(pendingMicrophone.prefix(count))
            var paddedReference = reference
            if count < Self.frameSize {
                microphone.append(contentsOf: repeatElement(0, count: Self.frameSize - count))
                paddedReference?.append(contentsOf: repeatElement(0, count: Self.frameSize - count))
            }
            let cleaned = Array(canceller.process(
                microphone: microphone, reference: paddedReference
            ).prefix(count))
            if reference == nil { missingReferenceSamples += Int64(count) }
            else { referenceSamplesMatched += Int64(count) }
            setStatus(reference == nil
                ? "系统参考暂未就绪，麦克风原音保留"
                : "外放回声消除已开启")
            do {
                try writeAndDeliver(cleaned, start: start)
            } catch {
                degrade(error)
                return
            }
            pendingMicrophone.removeFirst(count)
            pendingStart = start + Int64(count)
            if pendingMicrophone.isEmpty { pendingStart = nil }
            // Retain reference history slightly longer than the adaptive filter.
            references.removeAll { $0.end < start - 8_000 }
        }
    }

    private func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData?[0] else {
            throw MeetingEchoError.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { values in
            if let source = values.baseAddress { data.update(from: source, count: samples.count) }
        }
        return buffer
    }

    private func writeAndDeliver(_ samples: [Float], start: Int64) throws {
        guard let file else { throw MeetingEchoError.invalidAudio }
        if firstWrittenFrame == nil { firstWrittenFrame = start }
        let expected = firstWrittenFrame! + writtenFrames
        var silence = max(0, start - expected)
        guard silence <= Int64(Self.sampleRate * 10) else {
            throw MeetingEchoError.invalidAudio
        }
        while silence > 0 {
            let count = Int(min(silence, 1_600))
            try file.write(from: makeBuffer([Float](repeating: 0, count: count)))
            silence -= Int64(count)
            writtenFrames += Int64(count)
        }
        let buffer = try makeBuffer(samples)
        try file.write(from: buffer)
        writtenFrames += Int64(samples.count)
        deliver(Packet(buffer, epoch + Double(start) / Double(Self.sampleRate)))
    }

    private func deliver(_ packet: Packet) {
        let previous = deliveryTail
        let output = onOutput
        deliveryTail = Task { @MainActor [self, packet] in
            if let previous { await previous.value }
            guard !isCancelled else { return }
            output(packet.buffer, packet.hostTime)
        }
    }

    private func setStatus(_ status: String) {
        guard lastStatus != status else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard status == failure || now - lastStatusUpdate >= 0.5 else { return }
        lastStatus = status
        lastStatusUpdate = now
        let previous = deliveryTail
        let update = onStatus
        deliveryTail = Task { @MainActor [self] in
            if let previous { await previous.value }
            guard !isCancelled else { return }
            update(status)
        }
    }

    private func degrade(_ error: Error) {
        guard failure == nil else { return }
        failure = "外放回声消除不可用：\(error.localizedDescription)。麦克风原始录音保留。"
        // Deliver any already converted microphone tail without applying cancellation.
        if let start = pendingStart, !pendingMicrophone.isEmpty,
           let buffer = try? makeBuffer(pendingMicrophone) {
            deliver(Packet(buffer, epoch + Double(start) / Double(Self.sampleRate)))
        }
        pendingMicrophone.removeAll()
        pendingStart = nil
        references.removeAll()
        canceller.reset()
        setStatus(failure!)
    }

    deinit { timer?.cancel() }
}
