import Foundation

/// 单次会议的实时翻译状态。调用方负责模型请求和目标语言、模型等配置校验。
public struct LiveTranslationQueue {
    private struct Entry {
        var segment: TranscriptSegment
        var lastTextChange: Date
        var isFinal: Bool
        var requiresFinal: Bool
        var attempts = 0
        var retryAt = Date.distantPast
    }

    private let stabilityInterval: TimeInterval
    private var pending: [UUID: Entry] = [:]
    private var translatedTexts: [UUID: String] = [:]
    private var pausedTexts: [UUID: String] = [:]
    private var failedEntries: [UUID: Entry] = [:]
    private var failureTexts: [UUID: String] = [:]
    private var requestNotBefore = Date.distantPast
    private var preservesPendingWhileSuspended = false
    public private(set) var failures: [UUID: LiveTranslationFailurePolicy.Failure] = [:]
    public private(set) var translations: [UUID: String] = [:]
    public private(set) var isSuspended = false

    public init(stabilityInterval: TimeInterval = 1.2) {
        self.stabilityInterval = stabilityInterval.isFinite ? max(0, stabilityInterval) : 1.2
    }

    public var hasPending: Bool { !pending.isEmpty }

    public func isPending(for segment: TranscriptSegment) -> Bool {
        pending[segment.id]?.segment.text == segment.text
    }

    public func isWaitingForSentence(for segment: TranscriptSegment) -> Bool {
        guard let entry = pending[segment.id], entry.segment.text == segment.text else { return false }
        return entry.requiresFinal && !entry.isFinal
    }

    public func failure(for segment: TranscriptSegment) -> LiveTranslationFailurePolicy.Failure? {
        guard failureTexts[segment.id] == segment.text else { return nil }
        return failures[segment.id]
    }

    public mutating func update(_ segment: TranscriptSegment, isFinal: Bool, now: Date,
                                requiresFinal: Bool = false) {
        guard translatedTexts[segment.id] != segment.text else { return }
        if failureTexts[segment.id] != segment.text {
            failures.removeValue(forKey: segment.id)
            failureTexts.removeValue(forKey: segment.id)
            failedEntries.removeValue(forKey: segment.id)
        } else if var entry = failedEntries[segment.id] {
            // 相同文字的重复最终回调不能重新开始已用尽的自动重试。
            entry.segment = segment
            entry.isFinal = entry.isFinal || isFinal
            entry.requiresFinal = requiresFinal
            failedEntries[segment.id] = entry
            return
        }

        // 原文被更正后，旧译文立即失效；即使原文稍后恢复，也要重新排队。
        translations.removeValue(forKey: segment.id)
        translatedTexts.removeValue(forKey: segment.id)

        if isSuspended, !preservesPendingWhileSuspended {
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
            entry.requiresFinal = requiresFinal
            pending[segment.id] = entry
        } else {
            pending[segment.id] = Entry(
                segment: segment, lastTextChange: now, isFinal: isFinal,
                requiresFinal: requiresFinal
            )
        }
    }

    public func next(now: Date, flush: Bool = false) -> TranscriptSegment? {
        guard !isSuspended, now >= requestNotBefore else { return nil }
        return pending.values.filter {
            now >= $0.retryAt && (flush || $0.isFinal ||
                (!$0.requiresFinal && now.timeIntervalSince($0.lastTextChange) >= stabilityInterval)
            )
        }.sorted {
            let lhsStart = $0.segment.start.isFinite ? $0.segment.start : .greatestFiniteMagnitude
            let rhsStart = $1.segment.start.isFinite ? $1.segment.start : .greatestFiniteMagnitude
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return $0.segment.id.uuidString < $1.segment.id.uuidString
        }.first?.segment
    }

    @discardableResult
    public mutating func commit(_ translation: String, for segment: TranscriptSegment) -> Bool {
        guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pending[segment.id]?.segment.text == segment.text else { return false }
        translations[segment.id] = translation
        translatedTexts[segment.id] = segment.text
        pending.removeValue(forKey: segment.id)
        failures.removeValue(forKey: segment.id)
        failureTexts.removeValue(forKey: segment.id)
        failedEntries.removeValue(forKey: segment.id)
        return true
    }

    @discardableResult
    public mutating func recordFailure(_ error: Error, for segment: TranscriptSegment, now: Date)
        -> LiveTranslationFailurePolicy.Failure? {
        guard var entry = pending[segment.id], entry.segment.text == segment.text else { return nil }
        entry.attempts += 1
        let failure = LiveTranslationFailurePolicy.failure(for: error, attempts: entry.attempts)
        failures[segment.id] = failure
        failureTexts[segment.id] = segment.text
        // 全局退避与本段是否已用尽自动重试独立，不能把限流传给下一段。
        switch failure.category {
        case .rateLimited:
            requestNotBefore = max(requestNotBefore, now.addingTimeInterval(5))
        case .network, .service:
            requestNotBefore = max(requestNotBefore, now.addingTimeInterval(2))
        default: break
        }
        switch failure.recovery {
        case .retry(let delay):
            entry.retryAt = now.addingTimeInterval(delay)
            pending[segment.id] = entry
        case .retryManually:
            failedEntries[segment.id] = entry
            pending.removeValue(forKey: segment.id)
        case .pause:
            pending[segment.id] = entry
            // 配置/鉴权故障暂停请求，但保留其他段，显式恢复后继续。
            isSuspended = true
            preservesPendingWhileSuspended = true
        }
        return failure
    }

    @discardableResult
    public mutating func retry(_ segment: TranscriptSegment, now: Date) -> Bool {
        guard failure(for: segment) != nil,
              var entry = failedEntries[segment.id] ?? pending[segment.id],
              entry.segment.text == segment.text else { return false }
        entry.segment = segment
        entry.attempts = 0
        entry.retryAt = now
        pending[segment.id] = entry
        failedEntries.removeValue(forKey: segment.id)
        failures.removeValue(forKey: segment.id)
        failureTexts.removeValue(forKey: segment.id)
        pausedTexts.removeValue(forKey: segment.id)
        // 重试其他片段不能绕过仍有效的限流/网络退避。
        requestNotBefore = max(requestNotBefore, now)
        isSuspended = false
        preservesPendingWhileSuspended = false
        return true
    }

    public mutating func clearPending() {
        pending.removeAll()
    }

    /// 停止录音后取消自动请求，未完成段保留在可手动重试状态。
    public mutating func parkPendingForRetry() {
        for (id, entry) in pending {
            let failure: LiveTranslationFailurePolicy.Failure
            if let existing = failures[id], failureTexts[id] == entry.segment.text {
                let recovery: LiveTranslationFailurePolicy.Recovery
                if existing.recovery == .pause { recovery = .pause }
                else { recovery = .retryManually }
                failure = .init(category: existing.category, recovery: recovery,
                                message: existing.message, attempts: existing.attempts)
            } else {
                failure = .init(category: .unknown, recovery: .retryManually,
                                message: "结束录音时本段翻译未完成，未保存译文。可重试此段。",
                                attempts: entry.attempts)
            }
            failures[id] = failure
            failureTexts[id] = entry.segment.text
            failedEntries[id] = entry
        }
        pending.removeAll()
    }

    public mutating func suspend() {
        isSuspended = true
        preservesPendingWhileSuspended = false
        for (id, entry) in pending {
            pausedTexts[id] = entry.segment.text
            if failures[id] != nil { failedEntries[id] = entry }
        }
        pending.removeAll()
    }

    public mutating func resume() {
        isSuspended = false
        preservesPendingWhileSuspended = false
    }

    public mutating func remove(id: UUID) {
        pending.removeValue(forKey: id)
        translatedTexts.removeValue(forKey: id)
        translations.removeValue(forKey: id)
        pausedTexts.removeValue(forKey: id)
        failedEntries.removeValue(forKey: id)
        failures.removeValue(forKey: id)
        failureTexts.removeValue(forKey: id)
    }

    public func translation(for segment: TranscriptSegment) -> String? {
        guard translatedTexts[segment.id] == segment.text else { return nil }
        return translations[segment.id]
    }
}
