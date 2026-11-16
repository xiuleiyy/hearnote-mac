import AVFoundation
import Foundation

enum RecordingSinkError: LocalizedError {
    case invalidInput
    case conversion
    case incompleteConversion
    case backwardsClock

    var errorDescription: String? {
        switch self {
        case .invalidInput: return "当前麦克风音频格式不可用。"
        case .conversion: return "麦克风音频无法转换为当前录音格式。"
        case .incompleteConversion: return "麦克风切换时的最后一段音频未能完整转换。"
        case .backwardsClock: return "麦克风音频时间发生倒退。"
        }
    }
}

/// One file and one host timeline outlive every hardware input lease. The lock
/// fences obsolete taps before writes, conversion and downstream callbacks.
final class RecordingSink: @unchecked Sendable {
    struct Result {
        let inputID: UUID
        let buffer: AVAudioPCMBuffer?
        let hostTime: Double
        let level: Double
        let elapsed: Double
        let error: Error?
    }

    let url: URL
    let format: AVAudioFormat
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var firstHostTime: Double?
    private var failed = false
    private var inputID: UUID?
    private var epochInputID: UUID?
    private var pendingResults: [Result] = []
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var epochStart: Double?
    private var inputFrames: AVAudioFramePosition = 0
    private var outputFrames: AVAudioFramePosition = 0
    private var convertedAhead: [AVAudioPCMBuffer] = []
    private let onCapturedBuffer: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?

    init(url: URL, format: AVAudioFormat,
         onCapturedBuffer: (@Sendable (AVAudioPCMBuffer, Double) -> Void)? = nil) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let stable = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: format.sampleRate,
                                        channels: format.channelCount, interleaved: false) else {
            throw RecordingSinkError.invalidInput
        }
        self.url = url
        self.format = stable
        self.onCapturedBuffer = onCapturedBuffer
        file = try AVAudioFile(forWriting: url, settings: stable.settings,
                              commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func activateInput(_ id: UUID, format source: AVAudioFormat) throws {
        lock.lock()
        defer { lock.unlock() }
        guard file != nil, !failed, inputID == nil else { throw RecordingSinkError.invalidInput }
        try prepareConverter(source)
        inputID = id
        epochInputID = id
    }

    /// notify only schedules a drain. Saved results remain ordered in the sink
    /// until the main actor takes them, including during retirement and Stop.
    func consume(_ buffer: AVAudioPCMBuffer, hostTime: Double, input id: UUID,
                 notify: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !failed, inputID == id else { return }
        defer { if !pendingResults.isEmpty { notify() } }
        do {
            guard hostTime.isFinite, buffer.frameLength > 0,
                  buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
                  buffer.format.channelCount > 0 else { throw RecordingSinkError.invalidInput }
            if inputFormat != buffer.format {
                // The native format can change before the engine notification
                // reaches the main actor. Normalize it within the current lease.
                try finishEpoch(file: file)
                try prepareConverter(buffer.format)
            }
            if let epochStart, let inputFormat {
                let expected = epochStart + Double(inputFrames) / inputFormat.sampleRate
                let gap = hostTime - expected
                if gap < -0.25 { throw RecordingSinkError.backwardsClock }
                if gap > 0.02 {
                    try finishEpoch(file: file)
                    try prepareConverter(inputFormat)
                }
            }
            if epochStart == nil { epochStart = hostTime }
            inputFrames += AVAudioFramePosition(buffer.frameLength)
            if let converter {
                var supplied = false
                let capacity = try outputCapacity(for: buffer)
                for _ in 0..<32 {
                    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                        throw RecordingSinkError.conversion
                    }
                    var conversionError: NSError?
                    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                        if !supplied {
                            supplied = true
                            inputStatus.pointee = .haveData
                            return buffer
                        }
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    if status == .error {
                        if let conversionError { throw conversionError }
                        throw RecordingSinkError.conversion
                    }
                    try writeConverted(output, file: file)
                    if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { return }
                }
                throw RecordingSinkError.conversion
            } else {
                guard let copy = Self.copy(buffer, frames: buffer.frameLength, format: format) else {
                    throw RecordingSinkError.conversion
                }
                try writeConverted(copy, file: file)
            }
        } catch {
            failed = true
            pendingResults.append(Result(inputID: id, buffer: nil, hostTime: hostTime, level: 0,
                                         elapsed: Double(frames) / format.sampleRate, error: error))
        }
    }

    /// EOS drains the retired converter before another device can append.
    /// No old lease can write again, including while engine.stop is in flight.
    func retireInput(_ id: UUID) throws -> [Result] {
        lock.lock()
        defer { lock.unlock() }
        guard inputID == id else { return [] }
        inputID = nil
        if let file, !failed {
            do { try finishEpoch(file: file) }
            catch { recordFailure(error, input: id) }
        }
        return takePendingLocked()
    }

    @discardableResult
    func close() throws -> [Result] {
        lock.lock()
        defer {
            inputID = nil
            // Finalize the writer header before callers open the saved file.
            // macOS 14 closes it by releasing the last AVAudioFile reference.
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
            lock.unlock()
        }
        if let file, !failed {
            do { try finishEpoch(file: file) }
            catch { recordFailure(error, input: epochInputID ?? UUID()) }
        }
        return takePendingLocked()
    }

    func takePendingResults() -> [Result] {
        lock.lock()
        defer { lock.unlock() }
        return takePendingLocked()
    }

    private func takePendingLocked() -> [Result] {
        let results = pendingResults
        pendingResults.removeAll(keepingCapacity: true)
        return results
    }

    private func recordFailure(_ error: Error, input: UUID) {
        failed = true
        pendingResults.append(Result(inputID: input, buffer: nil,
                                     hostTime: (firstHostTime ?? 0) + Double(frames) / format.sampleRate,
                                     level: 0, elapsed: Double(frames) / format.sampleRate, error: error))
    }

    var capturedStartHostTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return firstHostTime
    }

    private func prepareConverter(_ source: AVAudioFormat) throws {
        guard source.sampleRate.isFinite, source.sampleRate > 0, source.channelCount > 0 else {
            throw RecordingSinkError.invalidInput
        }
        if source == format {
            converter = nil
        } else {
            guard let prepared = AVAudioConverter(from: source, to: format) else {
                throw RecordingSinkError.conversion
            }
            // A route's source has no earlier input to prime from. EOS still
            // drains the streaming converter before its exact-duration trim.
            prepared.primeMethod = .none
            converter = prepared
        }
        inputFormat = source
        epochStart = nil
        inputFrames = 0
        outputFrames = 0
        convertedAhead.removeAll()
    }

    private func outputCapacity(for buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        let capacity = ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max) else {
            throw RecordingSinkError.invalidInput
        }
        return AVAudioFrameCount(capacity)
    }

    private var expectedOutputFrames: AVAudioFramePosition {
        guard let inputFormat else { return 0 }
        return AVAudioFramePosition((Double(inputFrames) * format.sampleRate / inputFormat.sampleRate).rounded())
    }

    private func finishEpoch(file: AVAudioFile) throws {
        defer {
            converter = nil
            epochStart = nil
            inputFrames = 0
            outputFrames = 0
            // Only EOS knows the complete input duration. Extra filter output
            // beyond that boundary is padding, rather than future input.
            convertedAhead.removeAll()
        }
        guard epochStart != nil else { return }
        if let converter {
            for _ in 0..<32 {
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                    throw RecordingSinkError.conversion
                }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if status == .error {
                    if let conversionError { throw conversionError }
                    throw RecordingSinkError.conversion
                }
                try writeConverted(output, file: file)
                if status == .endOfStream || status == .inputRanDry || output.frameLength == 0 { break }
            }
            guard outputFrames == expectedOutputFrames else { throw RecordingSinkError.incompleteConversion }
        }
    }

    private func writeConverted(_ converted: AVAudioPCMBuffer, file: AVAudioFile) throws {
        guard let epochStart, let epochInputID else { return }
        if converted.frameLength > 0 { convertedAhead.append(converted) }
        while !convertedAhead.isEmpty {
            let remaining = max(0, expectedOutputFrames - outputFrames)
            guard remaining > 0 else { return }
            let next = convertedAhead.removeFirst()
            let accepted = AVAudioFrameCount(min(AVAudioFramePosition(next.frameLength), remaining))
            guard let buffer = Self.copy(next, frames: accepted, format: format) else {
                throw RecordingSinkError.conversion
            }
            if accepted < next.frameLength {
                guard let future = Self.copy(next, frames: next.frameLength - accepted,
                                             format: format, offset: accepted) else {
                    throw RecordingSinkError.conversion
                }
                // Fractional rate conversion can produce one sample ahead of
                // the current input duration. Preserve it until later input.
                convertedAhead.insert(future, at: 0)
            }
            let hostTime = epochStart + Double(outputFrames) / format.sampleRate
            if firstHostTime == nil { firstHostTime = hostTime }
            if let firstHostTime {
                let gap = hostTime - firstHostTime - Double(frames) / format.sampleRate
                if gap > 0.02 {
                    try appendSilence(frames: AVAudioFramePosition((gap * format.sampleRate).rounded()), file: file)
                } else if gap < -0.25 {
                    throw RecordingSinkError.backwardsClock
                }
            }
            let savedHostTime = (firstHostTime ?? hostTime) + Double(frames) / format.sampleRate
            try file.write(from: buffer)
            frames += AVAudioFramePosition(accepted)
            outputFrames += AVAudioFramePosition(accepted)
            onCapturedBuffer?(buffer, savedHostTime)
            pendingResults.append(Result(inputID: epochInputID, buffer: buffer, hostTime: savedHostTime,
                                         level: Self.rms(buffer),
                                         elapsed: Double(frames) / format.sampleRate, error: nil))
        }
    }

    private func appendSilence(frames missing: AVAudioFramePosition, file: AVAudioFile) throws {
        guard missing > 0 else { return }
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
            throw RecordingSinkError.conversion
        }
        var remaining = missing
        while remaining > 0 {
            let count = AVAudioFrameCount(min(8192, remaining))
            silence.frameLength = count
            for channel in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = channel.mData { memset(data, 0, Int(channel.mDataByteSize)) }
            }
            try file.write(from: silence)
            frames += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount,
                             format: AVAudioFormat, offset: AVAudioFrameCount = 0) -> AVAudioPCMBuffer? {
        guard buffer.format == format, frames > 0, offset <= buffer.frameLength,
              frames <= buffer.frameLength - offset,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData,
                  source[index].mDataByteSize >= (frames + offset) * 4 else { return nil }
            memcpy(dst, src.advanced(by: Int(offset) * 4), Int(destination[index].mDataByteSize))
        }
        return copy
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Double = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = Double(data[0][index])
            sum += value * value
        }
        return min(1, sqrt(sum / Double(buffer.frameLength)) * 4)
    }
}
