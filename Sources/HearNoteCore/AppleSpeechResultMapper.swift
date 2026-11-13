import Foundation

/// SpeechAnalyzer 的 volatile 结果是同一音频范围的修订，不能逐次追加成永久字幕。
/// 每个输入源、每次识别会话持有自己的 mapper；时间采用 AnalyzerInput 的会议时间轴。
public struct AppleSpeechResultMapper {
    public struct Update: Equatable, Sendable {
        public let segment: TranscriptSegment
        public let isFinal: Bool
    }

    /// 文字按实际 audioTimeRange 的 run 切分；不按字符数量猜音频归属。
    public struct TimedText: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    private struct Pending {
        let segment: TranscriptSegment
        let fragments: [TimedText]
    }

    private struct TimeRange {
        let start: Double
        let end: Double
    }

    private var pending: [Pending] = []
    // isFinal 只固定它自己的范围，不能作为此前所有结果的 watermark。
    private var finalizedRanges: [TimeRange] = []
    private var finalizedThrough = -Double.infinity
    private var finished = false

    /// 跨已固定范围但没有足够真实时间属性可拆分的非空修订。只计数，不保存正文。
    public private(set) var unmappableRevisionCount = 0

    public init() {}

    public var hasPendingText: Bool { !pending.isEmpty }

    public mutating func receive(
        text: String, start: Double, end: Double, isFinal: Bool,
        resultsFinalizationTime: Double?, source: String?, timedText: [TimedText] = []
    ) -> [Update] {
        guard !finished, start.isFinite, end.isFinite, start >= 0, end >= start else { return [] }
        var updates: [Update] = []
        let usable = timedText.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
                && !$0.text.isEmpty && $0.start >= start - 0.000_001
                && $0.end <= end + 0.000_001
        }
        let available = unfinalizedRanges(start: start, end: end)
        if available.count == 1, let range = available.first,
           abs(range.start - start) <= 0.000_001, abs(range.end - end) <= 0.000_001 {
            updates.append(contentsOf: replacePending(
                text: text, start: start, end: end, isFinal: isFinal,
                resultsFinalizationTime: resultsFinalizationTime, source: source, timedText: usable
            ))
        } else if !available.isEmpty {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 撤回不需要推算文字的时间归属；只撤回仍可变化的范围。
                for range in available {
                    updates.append(contentsOf: replacePending(
                        text: "", start: range.start, end: range.end, isFinal: isFinal,
                        resultsFinalizationTime: resultsFinalizationTime, source: source, timedText: []
                    ))
                }
            } else {
                var unmappable = usable.isEmpty
                for range in available {
                    let fragments = usable.filter {
                        $0.start >= range.start - 0.000_001 && $0.end <= range.end + 0.000_001
                    }
                    if usable.contains(where: {
                        overlaps($0.start, $0.end, range.start, range.end)
                            && !fragments.contains($0)
                    }) {
                        unmappable = true
                    }
                    guard let fragmentStart = fragments.map(\.start).min(),
                          let fragmentEnd = fragments.map(\.end).max() else { continue }
                    updates.append(contentsOf: replacePending(
                        text: fragments.map(\.text).joined(), start: fragmentStart, end: fragmentEnd,
                        isFinal: isFinal, resultsFinalizationTime: resultsFinalizationTime,
                        source: source, timedText: fragments
                    ))
                }
                if unmappable, unmappableRevisionCount < Int.max { unmappableRevisionCount += 1 }
            }
        }
        if let time = resultsFinalizationTime, time.isFinite {
            // Apple 不保证未修改的 volatile 结果会重发 isFinal=true。
            // 只有模块公布的 watermark 才固定此前的全部范围。
            updates.append(contentsOf: finalize(through: time))
        }
        return updates
    }

    private mutating func replacePending(
        text: String, start: Double, end: Double, isFinal: Bool,
        resultsFinalizationTime: Double?, source: String?, timedText: [TimedText]
    ) -> [Update] {
        var updates: [Update] = []
        // 调用方已移除固定区间；此处只替换仍可修改的音频范围。
        do {
            let matching = pending.filter { overlaps($0.segment, start: start, end: end) }
            let retained = matching.filter { old in
                !old.fragments.contains { $0.end <= start + 0.000_001 }
            }.min { abs($0.segment.start - start) < abs($1.segment.start - start) }
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeAll { old in matching.contains { $0.segment.id == old.segment.id } }
            var retainedOldIDs: Set<UUID> = []
            for old in matching {
                let before = old.fragments.filter { $0.end <= start + 0.000_001 }
                let after = old.fragments.filter { $0.start >= end - 0.000_001 }
                if let prefix = preserved(before, from: old, id: old.segment.id) {
                    pending.append(prefix)
                    retainedOldIDs.insert(prefix.segment.id)
                    updates.append(Update(segment: prefix.segment, isFinal: false))
                }
                let replacementKeepsID = !content.isEmpty && old.segment.id == retained?.segment.id
                let suffixID = before.isEmpty && !replacementKeepsID ? old.segment.id : UUID()
                if let suffix = preserved(after, from: old, id: suffixID) {
                    pending.append(suffix)
                    if suffixID == old.segment.id { retainedOldIDs.insert(suffixID) }
                    updates.append(Update(segment: suffix.segment, isFinal: false))
                }
                if replacementKeepsID { retainedOldIDs.insert(old.segment.id) }
            }
            for old in matching where !retainedOldIDs.contains(old.segment.id) {
                var removed = old.segment
                removed.text = ""
                updates.append(Update(segment: removed, isFinal: false))
            }
            if !content.isEmpty {
                let segment = TranscriptSegment(
                    id: retained?.segment.id ?? UUID(), start: start, end: max(start + 0.01, end),
                    text: content, source: source
                )
                let resultIsFinal = isFinal || resultsFinalizationTime.map {
                    $0.isFinite && $0 + 0.000_001 >= end
                } == true
                if resultIsFinal || retained?.segment != segment {
                    updates.append(Update(segment: segment, isFinal: resultIsFinal))
                }
                if resultIsFinal {
                    rememberFinalRange(start: start, end: end)
                } else {
                    pending.append(Pending(
                        segment: segment, fragments: timedText.isEmpty
                            ? [TimedText(text: text, start: start, end: end)] : timedText
                    ))
                }
            }
        }
        return updates
    }

    /// 只在 analyzer 成功完成 finalizeAndFinishThroughEndOfInput 后调用。
    /// 取消、失败或超时保留临时文字，不伪装成模型已确认的最终结果。
    public mutating func finishSuccessfully() -> [Update] {
        guard !finished else { return [] }
        let updates = pending.sorted { $0.segment.start < $1.segment.start }.map {
            Update(segment: $0.segment, isFinal: true)
        }
        if let end = pending.map(\.segment.end).max() { finalizedThrough = max(finalizedThrough, end) }
        pending.removeAll()
        finalizedRanges.removeAll()
        finished = true
        return updates
    }

    private mutating func finalize(through time: Double) -> [Update] {
        var updates: [Update] = []
        var remaining: [Pending] = []
        for old in pending.sorted(by: { $0.segment.start < $1.segment.start }) {
            if old.segment.end <= time + 0.000_001 {
                updates.append(Update(segment: old.segment, isFinal: true))
                continue
            }
            let before = old.fragments.filter { $0.end <= time + 0.000_001 }
            let after = old.fragments.filter { $0.end > time + 0.000_001 }
            if let prefix = preserved(before, from: old, id: old.segment.id) {
                updates.append(Update(segment: prefix.segment, isFinal: true))
                if let suffix = preserved(after, from: old, id: UUID()) {
                    remaining.append(suffix)
                    updates.append(Update(segment: suffix.segment, isFinal: false))
                }
            } else {
                remaining.append(old)
            }
        }
        pending = remaining
        finalizedThrough = max(finalizedThrough, time)
        // 模块 watermark 已保护这些区间，不再逐条保存整场历史。
        finalizedRanges = finalizedRanges.compactMap {
            guard $0.end > finalizedThrough + 0.000_001 else { return nil }
            return TimeRange(start: max($0.start, finalizedThrough), end: $0.end)
        }
        return updates
    }

    private mutating func rememberFinalRange(start: Double, end: Double) {
        guard end > finalizedThrough + 0.000_001 else { return }
        var merged: [TimeRange] = []
        for range in (finalizedRanges + [TimeRange(start: start, end: end)])
            .sorted(by: { $0.start < $1.start }) {
            if let previous = merged.last, range.start <= previous.end + 0.000_001 {
                merged[merged.count - 1] = TimeRange(
                    start: previous.start, end: max(previous.end, range.end)
                )
            } else {
                merged.append(range)
            }
        }
        finalizedRanges = merged
    }

    private func unfinalizedRanges(start: Double, end: Double) -> [TimeRange] {
        let lowerBound = max(start, finalizedThrough)
        guard lowerBound <= end + 0.000_001 else { return [] }
        if abs(end - start) <= 0.000_001 {
            guard start + 0.000_001 >= finalizedThrough,
                  !finalizedRanges.contains(where: {
                      overlaps(start, end, $0.start, $0.end)
                  }) else { return [] }
            return [TimeRange(start: start, end: end)]
        }
        var available = [TimeRange(start: lowerBound, end: end)]
        for locked in finalizedRanges {
            available = available.flatMap { range -> [TimeRange] in
                guard overlaps(range.start, range.end, locked.start, locked.end) else {
                    return [range]
                }
                var parts: [TimeRange] = []
                if range.start < locked.start - 0.000_001 {
                    parts.append(TimeRange(start: range.start, end: min(range.end, locked.start)))
                }
                if range.end > locked.end + 0.000_001 {
                    parts.append(TimeRange(start: max(range.start, locked.end), end: range.end))
                }
                return parts
            }
        }
        return available.filter { $0.end - $0.start > 0.000_001 }
    }

    private func preserved(_ fragments: [TimedText], from old: Pending, id: UUID) -> Pending? {
        guard let first = fragments.first, let last = fragments.last else { return nil }
        let text = fragments.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Pending(
            segment: TranscriptSegment(
                id: id, start: first.start, end: max(first.start + 0.01, last.end),
                text: text, source: old.segment.source
            ),
            fragments: fragments
        )
    }

    private func overlaps(_ segment: TranscriptSegment, start: Double, end: Double) -> Bool {
        overlaps(segment.start, segment.end, start, end)
    }

    private func overlaps(_ start: Double, _ end: Double, _ otherStart: Double,
                          _ otherEnd: Double) -> Bool {
        min(end, otherEnd) - max(start, otherStart) > 0.000_001
            || abs(start - otherStart) <= 0.000_001
    }
}
