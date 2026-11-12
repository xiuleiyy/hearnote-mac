import Foundation

/// 单次会议的实时翻译状态。调用方负责模型请求和目标语言、模型等配置校验。
public struct LiveTranslationQueue {
    private struct Entry {
        var segment: TranscriptSegment
        var lastTextChange: Date
        var isFinal: Bool
    }

    private let stabilityInterval: TimeInterval
    private var pending: [UUID: Entry] = [:]
    private var translatedTexts: [UUID: String] = [:]
    private var pausedTexts: [UUID: String] = [:]
    public private(set) var translations: [UUID: String] = [:]
    public private(set) var isSuspended = false

    public init(stabilityInterval: TimeInterval = 1.2) {
        self.stabilityInterval = stabilityInterval.isFinite ? max(0, stabilityInterval) : 1.2
    }

    public var hasPending: Bool { !pending.isEmpty }

    public mutating func update(_ segment: TranscriptSegment, isFinal: Bool, now: Date) {
        guard translatedTexts[segment.id] != segment.text else { return }

        // 原文被更正后，旧译文立即失效；即使原文稍后恢复，也要重新排队。
        translations.removeValue(forKey: segment.id)
        translatedTexts.removeValue(forKey: segment.id)

        if isSuspended {
            // 暂停期间仍记录 Speech 的最新修订，恢复时相同文字不会因最终回调而补翻。
            pausedTexts[segment.id] = segment.text
            pending.removeValue(forKey: segment.id)
            return
        }
        guard pausedTexts[segment.id] != segment.text else { return }
        pausedTexts.removeValue(forKey: segment.id)

        if var entry = pending[segment.id], entry.segment.text == segment.text {
            // 时间戳更新不改变文字稳定计时；已经稳定的同一文字继续保持可提交状态。
            entry.segment = segment
            entry.isFinal = entry.isFinal || isFinal
            pending[segment.id] = entry
        } else {
            pending[segment.id] = Entry(
                segment: segment, lastTextChange: now, isFinal: isFinal
            )
        }
    }

    public func next(now: Date, flush: Bool = false) -> TranscriptSegment? {
        pending.values.filter {
            flush || $0.isFinal || now.timeIntervalSince($0.lastTextChange) >= stabilityInterval
        }.sorted {
            let lhsStart = $0.segment.start.isFinite ? $0.segment.start : .greatestFiniteMagnitude
            let rhsStart = $1.segment.start.isFinite ? $1.segment.start : .greatestFiniteMagnitude
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return $0.segment.id.uuidString < $1.segment.id.uuidString
        }.first?.segment
    }

    @discardableResult
    public mutating func commit(_ translation: String, for segment: TranscriptSegment) -> Bool {
        guard pending[segment.id]?.segment.text == segment.text else { return false }
        translations[segment.id] = translation
        translatedTexts[segment.id] = segment.text
        pending.removeValue(forKey: segment.id)
        return true
    }

    public mutating func clearPending() {
        pending.removeAll()
    }

    public mutating func suspend() {
        isSuspended = true
        for (id, entry) in pending {
            pausedTexts[id] = entry.segment.text
        }
        pending.removeAll()
    }

    public mutating func resume() {
        isSuspended = false
    }

    public mutating func remove(id: UUID) {
        pending.removeValue(forKey: id)
        translatedTexts.removeValue(forKey: id)
        translations.removeValue(forKey: id)
        pausedTexts.removeValue(forKey: id)
    }

    public func translation(for segment: TranscriptSegment) -> String? {
        guard translatedTexts[segment.id] == segment.text else { return nil }
        return translations[segment.id]
    }
}
