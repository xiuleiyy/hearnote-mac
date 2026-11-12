import Foundation
import XCTest
@testable import HearNoteCore

final class AcousticEchoCancellerTests: XCTestCase {
    private let rate = 16_000
    private let frameSize = 320

    func testDelayedRoomEchoEnergyFallsAfterAdaptation() throws {
        let reference = speechLikeNoise(seconds: 8, seed: 1)
        let microphone = roomEcho(reference)
        let filter = try AcousticEchoCanceller()
        let output = process(microphone, reference: reference, with: filter)
        let measured = (5 * rate)..<reference.count
        let ratio = energy(output[measured]) / energy(microphone[measured])
        print("Synthetic AEC echo-only residual energy ratio: \(ratio)")
        // Synthetic room FIR, not a measured real-device accuracy guarantee.
        XCTAssertLessThan(ratio, 0.03, "Residual synthetic echo energy ratio: \(ratio)")
        XCTAssertEqual(output.count, microphone.count)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testDoubleTalkRetainsIndependentLocalSpeech() throws {
        let reference = speechLikeNoise(seconds: 8, seed: 7)
        let echo = roomEcho(reference)
        var local = speechLikeNoise(seconds: 8, seed: 39)
        // Let the filter first learn the loudspeaker path, then both speak.
        for index in 0..<(5 * rate) { local[index] = 0 }
        let microphone = zip(echo, local).map(+)
        let filter = try AcousticEchoCanceller()
        let output = process(microphone, reference: reference, with: filter)
        let dryFilter = try AcousticEchoCanceller()
        let dryLocal = process(local, reference: [Float](repeating: 0, count: local.count),
                               with: dryFilter)
        let measured = (6 * rate)..<reference.count
        let localEnergy = energy(local[measured])
        let projectedGain = zip(output[measured], local[measured])
            .reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / localEnergy
        // Speex applies a DC notch even with a silent reference. Compare the
        // double-talk result against that same ordinary microphone response,
        // while separately requiring preservation of the original speech gain.
        let errorEnergy = zip(output[measured], dryLocal[measured])
            .reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) }
        print("Synthetic AEC double-talk local gain: \(projectedGain); residual energy/local: \(errorEnergy / localEnergy)")
        XCTAssertGreaterThan(projectedGain, 0.85, "Local speech projected gain: \(projectedGain)")
        XCTAssertLessThan(projectedGain, 1.15)
        XCTAssertLessThan(errorEnergy / localEnergy, 0.08,
                          "Local speech error energy ratio: \(errorEnergy / localEnergy)")
    }

    func testVoicedSyllablesWithLongRoomDelayConverge() throws {
        let reference = formantSyllables(seconds: 12, seed: 5, pitch: 123)
        let microphone = delayedRoomEcho(reference, delay: 160 * rate / 1_000)
        let filter = try AcousticEchoCanceller()
        let output = process(microphone, reference: reference, with: filter)
        let measured = (8 * rate)..<reference.count
        let ratio = energy(output[measured]) / energy(microphone[measured])
        // A voiced/unvoiced source and room path lasting 230 ms exercise a
        // longer valid acoustic path than the ordinary 15 ms synthetic case.
        XCTAssertLessThan(ratio, 0.05, "Long-delay syllable echo energy ratio: \(ratio)")
        XCTAssertEqual(output.count, microphone.count)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testWeakLocalVoiceSurvivesStrongerVoicedRoomEcho() throws {
        let reference = formantSyllables(seconds: 12, seed: 5, pitch: 123)
        let echo = delayedRoomEcho(reference, delay: 80 * rate / 1_000)
        var local = formantSyllables(seconds: 12, seed: 71, pitch: 191).map { $0 * 0.10 }
        for index in 0..<(5 * rate) { local[index] = 0 }
        let microphone = zip(echo, local).map(+)
        let filter = try AcousticEchoCanceller()
        let output = process(microphone, reference: reference, with: filter)
        let dryFilter = try AcousticEchoCanceller()
        let dryLocal = process(local, reference: [Float](repeating: 0, count: local.count),
                               with: dryFilter)
        let measured = (8 * rate)..<reference.count
        let localEnergy = energy(local[measured])
        let dryEnergy = energy(dryLocal[measured])
        let gain = zip(output[measured], dryLocal[measured])
            .reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / dryEnergy
        let error = zip(output[measured], dryLocal[measured])
            .reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / localEnergy
        // A loudspeaker-only mute fails the gain assertion; raw microphone
        // bypass fails the residual-error bound when local speech is much softer.
        XCTAssertGreaterThan(dryEnergy / localEnergy, 0.85)
        XCTAssertGreaterThan(gain, 0.85, "Weak local voice projected gain: \(gain)")
        XCTAssertLessThan(gain, 1.15)
        XCTAssertLessThan(error, 0.50, "Weak local voice error/local energy: \(error)")
    }

    func testWeakLocalVoiceFromFirstFrameIsPreserved() throws {
        let reference = formantSyllables(seconds: 3, seed: 5, pitch: 123)
        let echo = delayedRoomEcho(reference, delay: 80 * rate / 1_000)
        let local = formantSyllables(seconds: 3, seed: 71, pitch: 191).map { $0 * 0.10 }
        let microphone = zip(echo, local).map(+)
        let output = process(microphone, reference: reference,
                             with: try AcousticEchoCanceller())
        let dryLocal = process(local, reference: [Float](repeating: 0, count: local.count),
                               with: try AcousticEchoCanceller())
        // Both speakers start together: do not assume a far-end-only warmup.
        // This checks near-end preservation, not removal of cold-start echo.
        for second in 0..<3 {
            let measured = (second * rate)..<((second + 1) * rate)
            let dryEnergy = energy(dryLocal[measured])
            let gain = zip(output[measured], dryLocal[measured])
                .reduce(0.0) { $0 + Double($1.0) * Double($1.1) } / dryEnergy
            XCTAssertGreaterThan(dryEnergy / energy(local[measured]), 0.85)
            XCTAssertGreaterThan(gain, 0.85,
                                 "Cold-start local voice gain during second \(second): \(gain)")
            XCTAssertLessThan(gain, 1.20)
        }
        XCTAssertEqual(output.count, microphone.count)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }

    func testValidSilentReferencePreservesLocalSpeech() throws {
        let microphone = speechLikeNoise(seconds: 2, seed: 53)
        let filter = try AcousticEchoCanceller()
        let output = process(microphone, reference: [Float](repeating: 0, count: microphone.count),
                             with: filter)
        let measured = rate..<microphone.count
        let ratio = energy(output[measured]) / energy(microphone[measured])
        XCTAssertGreaterThan(ratio, 0.90)
        XCTAssertLessThan(ratio, 1.10)
    }

    func testMissingMalformedAndPartialReferenceFailOpen() throws {
        let filter = try AcousticEchoCanceller()
        let microphone = Array(speechLikeNoise(seconds: 1, seed: 4).prefix(frameSize))
        XCTAssertEqual(filter.process(microphone: microphone, reference: nil), microphone)
        XCTAssertEqual(filter.process(microphone: microphone, reference: [0]), microphone)
        var invalid = [Float](repeating: 0, count: frameSize)
        invalid[17] = .nan
        XCTAssertEqual(filter.process(microphone: microphone, reference: invalid), microphone)
        let tail = Array(microphone.prefix(31))
        XCTAssertEqual(filter.process(microphone: tail, reference: Array(invalid.prefix(31))), tail)
        XCTAssertEqual(filter.process(microphone: [], reference: []), [])
    }

    func testFrameDiagnosticsDistinguishFilteringFromFailOpen() throws {
        let filter = try AcousticEchoCanceller()
        let microphone = Array(speechLikeNoise(seconds: 1, seed: 43).prefix(frameSize))
        let silent = [Float](repeating: 0, count: frameSize)
        XCTAssertEqual(filter.lastFrameDisposition, .notProcessed)
        XCTAssertNil(filter.lastInputRMS)
        XCTAssertNil(filter.lastOutputRMS)
        XCTAssertNil(filter.lastReferenceRMS)

        let filtered = filter.process(microphone: microphone, reference: silent)
        XCTAssertEqual(filter.lastFrameDisposition, .processed)
        XCTAssertEqual(try XCTUnwrap(filter.lastInputRMS),
                       sqrt(energy(microphone[...]) / Double(frameSize)), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(filter.lastOutputRMS),
                       sqrt(energy(filtered[...]) / Double(frameSize)), accuracy: 1e-12)
        XCTAssertEqual(filter.lastReferenceRMS, 0)

        XCTAssertEqual(filter.process(microphone: microphone, reference: nil), microphone)
        XCTAssertEqual(filter.lastFrameDisposition, .missingReference)
        XCTAssertEqual(filter.lastInputRMS, filter.lastOutputRMS)
        XCTAssertNil(filter.lastReferenceRMS)

        var malformed = silent
        malformed[23] = .nan
        XCTAssertEqual(filter.process(microphone: microphone, reference: malformed), microphone)
        XCTAssertEqual(filter.lastFrameDisposition, .invalidReference)
        XCTAssertEqual(filter.lastInputRMS, filter.lastOutputRMS)
        XCTAssertNil(filter.lastReferenceRMS)

        let invalidMicrophone = [Float](repeating: 4, count: frameSize)
        XCTAssertEqual(filter.process(microphone: invalidMicrophone, reference: silent),
                       invalidMicrophone)
        XCTAssertEqual(filter.lastFrameDisposition, .invalidMicrophone)
        XCTAssertEqual(filter.lastInputRMS, 4)
        XCTAssertEqual(filter.lastOutputRMS, 4)
        XCTAssertEqual(filter.lastReferenceRMS, 0)

        filter.reset()
        XCTAssertEqual(filter.lastFrameDisposition, .notProcessed)
        XCTAssertNil(filter.lastInputRMS)
        XCTAssertNil(filter.lastOutputRMS)
        XCTAssertNil(filter.lastReferenceRMS)
    }

    func testResetDiscardsPreviousMeetingFilterHistory() throws {
        let reference = speechLikeNoise(seconds: 4, seed: 17)
        let filter = try AcousticEchoCanceller()
        _ = process(roomEcho(reference), reference: reference, with: filter)
        filter.reset()
        let fresh = try AcousticEchoCanceller()
        let local = Array(speechLikeNoise(seconds: 1, seed: 31).prefix(frameSize))
        let silent = [Float](repeating: 0, count: frameSize)
        XCTAssertEqual(filter.process(microphone: local, reference: silent),
                       fresh.process(microphone: local, reference: silent))
    }

    func testMissingReferenceResetsStaleHistoryBeforeNextLocalFrame() throws {
        let reference = speechLikeNoise(seconds: 3, seed: 19)
        let filter = try AcousticEchoCanceller()
        _ = process(roomEcho(reference), reference: reference, with: filter)
        let local = Array(speechLikeNoise(seconds: 1, seed: 91).prefix(frameSize))
        XCTAssertEqual(filter.process(microphone: local, reference: nil), local)
        let fresh = try AcousticEchoCanceller()
        let silent = [Float](repeating: 0, count: frameSize)
        XCTAssertEqual(filter.process(microphone: local, reference: silent),
                       fresh.process(microphone: local, reference: silent))
    }

    func testOutOfRangeAudioFailsOpenAndConfigurationBoundsAreSafe() throws {
        XCTAssertThrowsError(try AcousticEchoCanceller(sampleRate: 0))
        XCTAssertThrowsError(try AcousticEchoCanceller(frameSize: 0))
        XCTAssertThrowsError(try AcousticEchoCanceller(filterLength: -1))
        XCTAssertThrowsError(try AcousticEchoCanceller(filterLength: 100_000))
        let filter = try AcousticEchoCanceller()
        let clipped = (0..<frameSize).map { $0.isMultiple(of: 2) ? Float(4) : Float(-4) }
        let result = filter.process(microphone: clipped,
                                    reference: [Float](repeating: 0, count: frameSize))
        XCTAssertEqual(result, clipped)
        let local = [Float](repeating: 0.05, count: frameSize)
        XCTAssertEqual(filter.process(microphone: local, reference: clipped), local)
    }

    private func process(_ microphone: [Float], reference: [Float],
                         with filter: AcousticEchoCanceller) -> [Float] {
        precondition(microphone.count == reference.count)
        precondition(microphone.count.isMultiple(of: frameSize))
        var output: [Float] = []
        output.reserveCapacity(microphone.count)
        for start in stride(from: 0, to: microphone.count, by: frameSize) {
            output += filter.process(
                microphone: Array(microphone[start..<(start + frameSize)]),
                reference: Array(reference[start..<(start + frameSize)])
            )
        }
        return output
    }

    /// Deterministic independent speech-band signals; no real recording fixtures.
    private func speechLikeNoise(seconds: Int, seed: UInt64) -> [Float] {
        var state = seed
        var previous: Double = 0
        return (0..<(seconds * rate)).map { index in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let white = Double(state >> 11) / Double(UInt64.max >> 11) * 2 - 1
            previous = 0.72 * previous + 0.28 * white
            let envelope = 0.6 + 0.4 * sin(Double(index) / Double(rate) * 7)
            return Float(previous * envelope * 0.42)
        }
    }

    private func roomEcho(_ reference: [Float]) -> [Float] {
        reference.indices.map { index in
            var sample: Float = 0
            for (delay, gain): (Int, Float) in [(240, 0.68), (800, 0.21), (1_400, -0.09)] {
                if index >= delay { sample += reference[index - delay] * gain }
            }
            return sample
        }
    }

    /// Voiced harmonics, formants, unvoiced noise and syllable gaps; fully synthetic.
    private func formantSyllables(seconds: Int, seed: UInt64, pitch: Double) -> [Float] {
        var state = seed
        var phase: Double = 0
        var lastNoise: Double = 0
        let centers = [(480.0, 130.0), (1_500.0, 250.0), (2_700.0, 350.0)]
        let weights = (1...28).map { harmonic -> Double in
            let frequency = Double(harmonic) * pitch
            let shaped = centers.reduce(0.0) {
                $0 + exp(-pow((frequency - $1.0) / $1.1, 2))
            }
            return (0.15 + shaped) / Double(harmonic)
        }
        let normalization = weights.reduce(0, +)
        return (0..<(seconds * rate)).map { index in
            let time = Double(index) / Double(rate)
            phase += 2 * .pi * pitch * (1 + 0.06 * sin(time * 4.1)) / Double(rate)
            var voiced: Double = 0
            for harmonic in 1...28 {
                voiced += weights[harmonic - 1] * sin(phase * Double(harmonic))
            }
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let noise = Double(state >> 11) / Double(UInt64.max >> 11) * 2 - 1
            let fricative = noise - lastNoise * 0.75
            lastNoise = noise
            let cycle = time.truncatingRemainder(dividingBy: 0.43)
            let envelope = cycle < 0.34 ? pow(sin(cycle / 0.34 * .pi), 0.55) : 0
            return Float(envelope * (0.30 * voiced / normalization + 0.035 * fricative))
        }
    }

    private func delayedRoomEcho(_ reference: [Float], delay: Int) -> [Float] {
        reference.indices.map { index in
            var sample: Float = 0
            for (extra, gain): (Int, Float) in [(0, 0.80), (320, 0.176), (1_120, -0.088)] {
                let lag = delay + extra
                if index >= lag { sample += reference[index - lag] * gain }
            }
            return sample
        }
    }

    private func energy(_ samples: ArraySlice<Float>) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }
}
