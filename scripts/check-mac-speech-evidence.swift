import AVFoundation
import Foundation
import HearNoteCore

/// Synthetic PCM only: no Speech model, permissions, microphone or network access.
@main
struct MacSpeechEvidenceCheck {
    static func main() throws {
        var checks = 0
        var reportedByteMetadata = false
        func expect(_ actual: AppleSpeechAudioEvidence.Content,
                    _ expected: AppleSpeechAudioEvidence.Content, _ detail: String) throws {
            guard actual == expected else { throw CheckFailure(detail: detail) }
            checks += 1
        }

        let formats: [AVAudioCommonFormat] = [
            .pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32
        ]
        for common in formats {
            for channels: AVAudioChannelCount in [1, 2] {
                for interleaved in [false, true] {
                    let buffer = try makeBuffer(common, channels: channels, interleaved: interleaved)
                    let detail = "\(common.rawValue)/channels=\(channels)/interleaved=\(interleaved)"
                    try expect(AppleSpeechPCMScanner.content(of: buffer), .exactlyZero,
                               "zero: \(detail)")

                    let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    let channel = channels == 2 && !interleaved ? 1 : 0
                    let sample = channels == 2 && interleaved ? 1 : 0
                    guard let data = buffers[channel].mData else {
                        throw CheckFailure(detail: "missing synthetic PCM")
                    }
                    switch common {
                    case .pcmFormatFloat32:
                        let samples = data.assumingMemoryBound(to: Float.self)
                        samples[sample] = -.zero
                        try expect(AppleSpeechPCMScanner.content(of: buffer), .exactlyZero,
                                   "negative zero: \(detail)")
                        samples[sample] = .leastNonzeroMagnitude
                    case .pcmFormatFloat64:
                        let samples = data.assumingMemoryBound(to: Double.self)
                        samples[sample] = -.zero
                        try expect(AppleSpeechPCMScanner.content(of: buffer), .exactlyZero,
                                   "negative zero: \(detail)")
                        samples[sample] = .leastNonzeroMagnitude
                    case .pcmFormatInt16:
                        data.assumingMemoryBound(to: Int16.self)[sample] = 1
                    case .pcmFormatInt32:
                        data.assumingMemoryBound(to: Int32.self)[sample] = 1
                    default:
                        throw CheckFailure(detail: "unsupported fixture")
                    }
                    try expect(AppleSpeechPCMScanner.content(of: buffer), .nonzero,
                               "weak nonzero on every layout/channel: \(detail)")

                    zero(buffer)
                    let suppliedFormat = buffer.format
                    let suppliedFrames = buffer.frameLength
                    let originalByteSize = buffers[0].mDataByteSize
                    buffers[0].mDataByteSize = 1
                    let mutatedByteSize = buffers[0].mDataByteSize
                    // Scan the held raw list before reacquiring any AV buffer
                    // property that could restore its expected byte length.
                    let incomplete = AppleSpeechPCMScanner.content(
                        in: buffers, format: suppliedFormat, frameLength: suppliedFrames
                    )
                    if !reportedByteMetadata {
                        let reobtained = UnsafeMutableAudioBufferListPointer(
                            buffer.mutableAudioBufferList
                        )
                        let reobtainedByteSize = reobtained[0].mDataByteSize
                        print("Apple Speech PCM metadata: originalBytes=\(originalByteSize) mutatedBytes=\(mutatedByteSize) reobtainedBytes=\(reobtainedByteSize)")
                        reportedByteMetadata = true
                    }
                    buffers[0].mDataByteSize = originalByteSize
                    try expect(incomplete, .unknown, "incomplete bytes: \(detail)")
                    try expect(AppleSpeechPCMScanner.content(
                        in: buffers, format: suppliedFormat, frameLength: suppliedFrames + 1
                    ), .unknown, "requested frames exceed raw bytes: \(detail)")
                    buffer.frameLength = 0
                    try expect(AppleSpeechPCMScanner.content(of: buffer), .unknown,
                               "no actual frames: \(detail)")
                }
            }
        }

        for interleaved in [false, true] {
            let buffer = try makeBuffer(.pcmFormatFloat32, channels: 2, interleaved: interleaved)
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let first = buffers[0].mData else {
                throw CheckFailure(detail: "missing stereo fixture")
            }
            first.assumingMemoryBound(to: Float.self)[0] = 0.25
            if interleaved {
                first.assumingMemoryBound(to: Float.self)[1] = -0.25
            } else {
                guard let second = buffers[1].mData else {
                    throw CheckFailure(detail: "missing second stereo channel")
                }
                second.assumingMemoryBound(to: Float.self)[0] = -0.25
            }
            try expect(AppleSpeechPCMScanner.content(of: buffer), .nonzero,
                       "opposite stereo phases must not count as zero downmix")
        }

        for common: AVAudioCommonFormat in [.pcmFormatFloat32, .pcmFormatFloat64] {
            let buffer = try makeBuffer(common, channels: 1, interleaved: false)
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard let data = buffers[0].mData else {
                throw CheckFailure(detail: "missing nonfinite fixture")
            }
            if common == .pcmFormatFloat32 {
                data.assumingMemoryBound(to: Float.self)[0] = .nan
                data.assumingMemoryBound(to: Float.self)[1] = .infinity
            } else {
                data.assumingMemoryBound(to: Double.self)[0] = .nan
                data.assumingMemoryBound(to: Double.self)[1] = .infinity
            }
            try expect(AppleSpeechPCMScanner.content(of: buffer), .unknown,
                       "nonfinite PCM must fail open")
        }

        let silence = try makeBuffer(.pcmFormatFloat32, channels: 2, interleaved: false)
        var system = AppleSpeechAudioEvidence()
        system.record(start: 0, duration: 10, content: AppleSpeechPCMScanner.content(of: silence))
        guard !system.accepts(text: "我", start: 1.68, end: 5.22) else {
            throw CheckFailure(detail: "covered zero system result")
        }
        guard system.accepts(text: "unknown future", start: 9.9, end: 10.2) else {
            throw CheckFailure(detail: "uncovered result must fail open")
        }
        checks += 2
        print("Apple Speech PCM evidence: \(checks) synthetic checks passed.")
    }

    private static func makeBuffer(
        _ common: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: common, sampleRate: 48_000, channels: channels, interleaved: interleaved
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64) else {
            throw CheckFailure(detail: "unable to construct synthetic PCM format")
        }
        buffer.frameLength = 64
        zero(buffer)
        return buffer
    }

    private static func zero(_ buffer: AVAudioPCMBuffer) {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audio in buffers {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
    }

    private struct CheckFailure: Error, CustomStringConvertible {
        let detail: String
        var description: String { "Apple Speech PCM evidence check failed: \(detail)" }
    }
}
