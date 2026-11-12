import CSpeexDSP

/// A synchronous, single-stream echo filter. Call only from one serial audio queue.
///
/// The caller supplies synchronized microphone and speaker-reference frames.
/// This type neither finds the output device nor resamples, buffers or aligns audio.
/// Missing/invalid reference data fails open, preserving microphone samples.
public final class AcousticEchoCanceller {
    public enum InitializationError: Error {
        case invalidConfiguration
        case unavailable
    }

    public let sampleRate: Int
    public let frameSize: Int
    public let filterLength: Int

    private let state: OpaquePointer
    private var microphonePCM: [Int16]
    private var referencePCM: [Int16]
    private var outputPCM: [Int16]

    public init(sampleRate: Int = 16_000, frameSize: Int = 320,
                filterLength: Int = 4_000) throws {
        guard (8_000...48_000).contains(sampleRate),
              (80...2_048).contains(frameSize),
              filterLength >= frameSize, filterLength <= sampleRate else {
            throw InitializationError.invalidConfiguration
        }
        guard let state = speex_echo_state_init(Int32(frameSize), Int32(filterLength)) else {
            throw InitializationError.unavailable
        }
        var rate = Int32(sampleRate)
        guard speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate) == 0 else {
            speex_echo_state_destroy(state)
            throw InitializationError.unavailable
        }
        self.state = state
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.filterLength = filterLength
        microphonePCM = [Int16](repeating: 0, count: frameSize)
        referencePCM = [Int16](repeating: 0, count: frameSize)
        outputPCM = [Int16](repeating: 0, count: frameSize)
    }

    deinit {
        speex_echo_state_destroy(state)
    }

    /// Float PCM is normalized to [-1, 1]. A complete reference frame is required.
    ///
    /// Silence is a valid reference: processing it preserves the adaptive filter's
    /// history, including a previous speaker frame's reverberant tail. There is no
    /// microphone gate or speaker-activity mute, so simultaneous local speech is
    /// passed through the adaptive canceller rather than discarded.
    public func process(microphone: [Float], reference: [Float]?) -> [Float] {
        guard microphone.count == frameSize,
              let reference, reference.count == frameSize,
              microphone.allSatisfy(Self.isNormalized),
              reference.allSatisfy(Self.isNormalized) else {
            // A gap invalidates filter history; stale reference must not remove
            // microphone speech when the next valid frame arrives.
            reset()
            return microphone
        }
        for index in 0..<frameSize {
            microphonePCM[index] = Self.quantize(microphone[index])
            referencePCM[index] = Self.quantize(reference[index])
        }
        microphonePCM.withUnsafeBufferPointer { mic in
            referencePCM.withUnsafeBufferPointer { ref in
                outputPCM.withUnsafeMutableBufferPointer { output in
                    speex_echo_cancellation(state, mic.baseAddress, ref.baseAddress,
                                           output.baseAddress)
                }
            }
        }
        return outputPCM.map { Float($0) / 32_768 }
    }

    /// Use after a clock discontinuity, changed audio route or missing reference.
    public func reset() {
        speex_echo_state_reset(state)
    }

    private static func quantize(_ value: Float) -> Int16 {
        Int16(max(-32_768, min(32_767, (value * 32_768).rounded())))
    }

    private static func isNormalized(_ value: Float) -> Bool {
        value.isFinite && (-1...1).contains(value)
    }
}
