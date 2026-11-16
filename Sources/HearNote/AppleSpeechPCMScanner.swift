import AVFoundation
import HearNoteCore

/// Inspect every submitted channel, rather than downmix RMS. Any real nonzero
/// value, including very quiet speech, prevents a digital-silence rejection.
enum AppleSpeechPCMScanner {
    static func content(of buffer: AVAudioPCMBuffer) -> AppleSpeechAudioEvidence.Content {
        guard buffer.frameLength > 0, buffer.format.channelCount > 0 else { return .unknown }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let channelsPerBuffer = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let expectedBuffers = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let description = buffer.format.streamDescription.pointee
        guard buffers.count == expectedBuffers,
              buffers.allSatisfy({ Int($0.mNumberChannels) == channelsPerBuffer }),
              description.mFormatID == kAudioFormatLinearPCM,
              description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
        else { return .unknown }
        var content = AppleSpeechAudioEvidence.Content.exactlyZero
        for audio in buffers {
            let (count, overflow) = Int(buffer.frameLength)
                .multipliedReportingOverflow(by: Int(audio.mNumberChannels))
            guard !overflow, count > 0, let data = audio.mData else { return .unknown }
            let next: AppleSpeechAudioEvidence.Content
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                guard packedLayout(description, bytesPerSample: MemoryLayout<Float>.stride,
                                   channelsPerBuffer: channelsPerBuffer) else { return .unknown }
                next = floatingContent(data, bytes: Int(audio.mDataByteSize), count: count,
                                       type: Float.self)
            case .pcmFormatFloat64:
                guard packedLayout(description, bytesPerSample: MemoryLayout<Double>.stride,
                                   channelsPerBuffer: channelsPerBuffer) else { return .unknown }
                next = floatingContent(data, bytes: Int(audio.mDataByteSize), count: count,
                                       type: Double.self)
            case .pcmFormatInt16:
                guard packedLayout(description, bytesPerSample: MemoryLayout<Int16>.stride,
                                   channelsPerBuffer: channelsPerBuffer) else { return .unknown }
                next = integerContent(data, bytes: Int(audio.mDataByteSize), count: count,
                                      type: Int16.self)
            case .pcmFormatInt32:
                guard packedLayout(description, bytesPerSample: MemoryLayout<Int32>.stride,
                                   channelsPerBuffer: channelsPerBuffer) else { return .unknown }
                next = integerContent(data, bytes: Int(audio.mDataByteSize), count: count,
                                      type: Int32.self)
            default:
                return .unknown
            }
            if next == .nonzero { return .nonzero }
            if next == .unknown { content = .unknown }
        }
        return content
    }

    private static func packedLayout(
        _ description: AudioStreamBasicDescription, bytesPerSample: Int, channelsPerBuffer: Int
    ) -> Bool {
        let (bytesPerFrame, overflow) = bytesPerSample
            .multipliedReportingOverflow(by: channelsPerBuffer)
        return !overflow && description.mBitsPerChannel == bytesPerSample * 8
            && description.mBytesPerFrame == bytesPerFrame
            && description.mFramesPerPacket == 1 && description.mBytesPerPacket == bytesPerFrame
    }

    private static func floatingContent<Value: BinaryFloatingPoint>(
        _ data: UnsafeMutableRawPointer, bytes: Int, count: Int, type: Value.Type
    ) -> AppleSpeechAudioEvidence.Content {
        guard bytes / MemoryLayout<Value>.stride >= count else { return .unknown }
        let samples = data.assumingMemoryBound(to: type)
        var content = AppleSpeechAudioEvidence.Content.exactlyZero
        for index in 0..<count {
            let value = samples[index]
            if !value.isFinite { content = .unknown }
            else if value != 0 { return .nonzero }
        }
        return content
    }

    private static func integerContent<Value: BinaryInteger>(
        _ data: UnsafeMutableRawPointer, bytes: Int, count: Int, type: Value.Type
    ) -> AppleSpeechAudioEvidence.Content {
        guard bytes / MemoryLayout<Value>.stride >= count else { return .unknown }
        let samples = data.assumingMemoryBound(to: type)
        return (0..<count).contains { samples[$0] != 0 } ? .nonzero : .exactlyZero
    }
}
