import Foundation

/// 文件识别可以在输入前补零值上下文；原媒体与字幕仍使用原文件时间轴。
/// 这是受控零点开口样例的缓解策略，不将前置静音当作模型准确率保证。
public struct AppleSpeechFileContext: Sendable {
    public struct PrefixChunk: Equatable, Sendable {
        public let frameOffset: Int64
        public let frameCount: Int
        public let start: Double
    }

    public static let maximumChunkFrameCount = 8192

    public let originalDuration: Double
    public let sampleRate: Double
    public let prefixFrameCount: Int64

    /// 以实际前置帧数计时，避免把分数帧的请求时长当作已投喂时长。
    public var prefixDuration: Double { Double(prefixFrameCount) / sampleRate }

    public init?(duration: Double, sampleRate: Double, prefixSeconds: Double = 2) {
        guard duration.isFinite, duration >= 0,
              sampleRate.isFinite, sampleRate > 0,
              prefixSeconds.isFinite, prefixSeconds >= 0 else { return nil }
        let frames = ceil(prefixSeconds * sampleRate)
        // Int64.max 转成 Double 会向上舍入；不能允许等于该上界后强转整数。
        guard frames.isFinite, frames >= 0, frames < Double(Int64.max) else { return nil }
        let count = Int64(frames)
        let actualPrefix = Double(count) / sampleRate
        guard actualPrefix.isFinite, (duration + actualPrefix).isFinite else { return nil }
        originalDuration = duration
        self.sampleRate = sampleRate
        prefixFrameCount = count
    }

    /// 按需取得下一块，避免先创建随输入规模增长的整段计划或 PCM。
    public func prefixChunk(at frameOffset: Int64) -> PrefixChunk? {
        guard frameOffset >= 0, frameOffset < prefixFrameCount else { return nil }
        let count = Int(min(
            prefixFrameCount - frameOffset, Int64(Self.maximumChunkFrameCount)
        ))
        return PrefixChunk(
            frameOffset: frameOffset, frameCount: count, start: Double(frameOffset) / sampleRate
        )
    }

    public func inputOffset(forOriginalOffset offset: Double) -> Double? {
        guard offset.isFinite, offset >= 0, offset <= originalDuration else { return nil }
        let shifted = offset + prefixDuration
        return shifted.isFinite ? shifted : nil
    }

    /// 保留实际语音的文字与 UUID，不补词；跨越前置边界的首句必须整体保留。
    /// 纯前置区结果转换成同 UUID 的撤回，避免其修订后留下旧的可见 partial。
    public func project(_ segment: TranscriptSegment) -> TranscriptSegment? {
        let isRetraction = segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var projected = segment
        guard segment.start.isFinite, segment.end.isFinite,
              segment.start >= 0, segment.end >= segment.start else {
            // 撤回依靠 UUID 删除旧 partial；不能因其时间非法而丢掉删除动作。
            guard isRetraction else { return nil }
            projected.start = 0
            projected.end = 0
            return projected
        }
        if !isRetraction, prefixFrameCount > 0, segment.end <= prefixDuration {
            projected.text = ""
            projected.start = 0
            projected.end = 0
            return projected
        }
        projected.start = min(originalDuration, max(0, segment.start - prefixDuration))
        projected.end = min(originalDuration, max(projected.start, segment.end - prefixDuration))
        return projected
    }
}
