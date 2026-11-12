import Foundation

/// 一份音频来源的一次核心窗口。只使用采集进度和 PCM 证据，不把墙钟等待当成静音。
public struct WhisperDecodeSchedulingPolicy {
    public enum Decision: Equatable, Sendable {
        case completedWindow
        case newAudio
        case newQuietSnapshot
        case quietConfirmation
    }

    private let minimumNewAudioDuration: Double
    private let maximumConfirmations: Int
    private var snapshotEnd: Double?
    private var snapshotCoreStart: Double?
    private var confirmations = 0

    public init(minimumNewAudioDuration: Double = 2.5, maximumConfirmations: Int = 2) {
        self.minimumNewAudioDuration = minimumNewAudioDuration.isFinite
            ? max(0.1, minimumNewAudioDuration) : 2.5
        self.maximumConfirmations = max(0, maximumConfirmations)
    }

    /// 调用方在实际启动解码时更新 lastDecodedEnd，且串行执行模型请求。
    /// 同一 audioEnd 最多额外确认两次，容许初识别 -> 修订 -> 一致确认。
    public mutating func nextDecision(
        audioEnd: Double, lastDecodedEnd: Double, coreStart: Double, complete: Bool,
        hasPendingSentence: Bool, hasTrailingSilence: Bool
    ) -> Decision? {
        guard audioEnd.isFinite, lastDecodedEnd.isFinite, coreStart.isFinite,
              audioEnd > coreStart, lastDecodedEnd >= coreStart else { return nil }
        if snapshotEnd != audioEnd || snapshotCoreStart != coreStart {
            snapshotEnd = audioEnd
            snapshotCoreStart = coreStart
            confirmations = 0
        }
        if complete { return .completedWindow }
        if audioEnd - lastDecodedEnd >= minimumNewAudioDuration { return .newAudio }
        guard hasTrailingSilence else { return nil }
        // 任意新增短句的 PCM 已含真实尾静音时，不必等待累计到 2.5 秒新音频。
        if audioEnd > lastDecodedEnd {
            return .newQuietSnapshot
        }
        guard hasPendingSentence, confirmations < maximumConfirmations else { return nil }
        confirmations += 1
        return .quietConfirmation
    }

    /// 仅真实尾静音的 partial 快照允许显示核心边界之外已采集的尾词。
    /// 稳定边界仍由调用方保留在 coreStart，后续确认而非墙钟负责定稿。
    public static func publicationEnd(
        coreEnd: Double, audioEnd: Double, complete: Bool, hasTrailingSilence: Bool
    ) -> Double {
        !complete && hasTrailingSilence ? max(coreEnd, audioEnd) : coreEnd
    }

    /// 与模型无声过滤使用相同的保守能量阈值，要求至少 0.8 秒实际采样。
    /// 默认 16 kHz／20 ms 帧；返回的起点仍是采集时间轴，不增加虚构静音。
    public static func trailingSilenceStart(
        samples: [Float], audioStart: Double, sampleRate: Double = 16_000
    ) -> Double? {
        guard audioStart.isFinite, sampleRate.isFinite, sampleRate > 0,
              sampleRate <= 192_000 else { return nil }
        let frameSize = max(1, Int(sampleRate * 0.02))
        var index = samples.count
        while index >= frameSize {
            let start = index - frameSize
            var energy: Double = 0
            for sample in samples[start..<index] {
                guard sample.isFinite else { return nil }
                energy += Double(sample) * Double(sample)
            }
            if sqrt(energy / Double(frameSize)) >= 0.0005 { break }
            index = start
        }
        guard samples.count - index >= Int(ceil(sampleRate * 0.8)) else { return nil }
        return audioStart + Double(index) / sampleRate
    }
}
