import Foundation

/// 新 Apple 输入允许时间跳跃，但禁止重叠或倒序。独立源各持有一份。
public struct AppleSpeechInputTimeline {
    public private(set) var end: Double?

    public init() {}

    /// duration 必须是实际转换后 PCM 的时长，避免重采样的帧舍入造成重叠。
    public mutating func place(duration: Double, requestedStart: Double?) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        let requested = requestedStart.flatMap { $0.isFinite ? max(0, $0) : nil }
        let start = max(end ?? 0, requested ?? end ?? 0)
        guard (start + duration).isFinite else { return nil }
        end = start + duration
        return start
    }
}

/// 限制尚未被 analyzer 从输入序列取走的 PCM。达到上限必须显式失败或等待，
/// 不能悄悄丢帧；文件转写使用等待，实时识别告警后仍由录音线路保存音频。
public final class AppleSpeechInputBudget: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumDuration: Double
    private let maximumBytes: Int
    private let maximumBuffers: Int
    private var reservations: [UUID: (Double, Int)] = [:]
    private var duration: Double = 0
    private var bytes: Int = 0

    public init(maximumDuration: Double = 45, maximumBytes: Int = 64 * 1024 * 1024,
                maximumBuffers: Int = 4096) {
        self.maximumDuration = maximumDuration.isFinite ? max(1, maximumDuration) : 45
        self.maximumBytes = max(1, maximumBytes)
        self.maximumBuffers = max(1, maximumBuffers)
    }

    public func reserve(duration incomingDuration: Double, bytes incomingBytes: Int) -> UUID? {
        guard incomingDuration.isFinite, incomingDuration > 0, incomingBytes > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard duration + incomingDuration <= maximumDuration,
              incomingBytes <= maximumBytes - bytes,
              reservations.count < maximumBuffers else { return nil }
        let id = UUID()
        reservations[id] = (incomingDuration, incomingBytes)
        duration += incomingDuration
        bytes += incomingBytes
        return id
    }

    public func consumed(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let value = reservations.removeValue(forKey: id) else { return }
        duration = max(0, duration - value.0)
        bytes = max(0, bytes - value.1)
    }
}
