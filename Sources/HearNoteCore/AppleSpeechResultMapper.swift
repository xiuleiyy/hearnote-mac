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

    private var pending: [Pending] = []
    private var finalizedThrough = -Double.infinity

    public init() {}

    public var hasPendingText: Bool { !pending.isEmpty }

    public mutating func receive(
        text: String, start: Double, end: Double, isFinal: Bool,
        resultsFinalizationTime: Double?, source: String?, timedText: [TimedText] = []
    ) -> [Update] {
        guard start.isFinite, end.isFinite, start >= 0, end >= start else { return [] }
        var updates: [Update] = []
        // Finalized ranges never change. A stale result must not revive a previous phrase.
        if start + 0.000_001 >= finalizedThrough {
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
                    finalizedThrough = max(finalizedThrough, end)
                } else {
                    let usable = timedText.filter {
                        $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
                            && !$0.text.isEmpty && $0.start >= start - 0.000_001
                            && $0.end <= end + 0.000_001
                    }
                    pending.append(Pending(
                        segment: segment, fragments: usable.isEmpty
                            ? [TimedText(text: text, start: start, end: end)] : usable
                    ))
                }
            }
        }
        if let time = resultsFinalizationTime, time.isFinite {
            // Apple 不保证未修改的 volatile 结果会重发 isFinal=true。
            // 必须同时处理模块公布的 finalization watermark。
            updates.append(contentsOf: finalize(through: time))
        }
        return updates
    }

    /// 只在 analyzer 成功完成 finalizeAndFinishThroughEndOfInput 后调用。
    /// 取消、失败或超时保留临时文字，不伪装成模型已确认的最终结果。
    public mutating func finishSuccessfully() -> [Update] {
        let updates = pending.sorted { $0.segment.start < $1.segment.start }.map {
            Update(segment: $0.segment, isFinal: true)
        }
        if let end = pending.map(\.segment.end).max() { finalizedThrough = max(finalizedThrough, end) }
        pending.removeAll()
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
        return updates
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
        min(segment.end, end) - max(segment.start, start) > 0.000_001
            || abs(segment.start - start) <= 0.000_001
    }
}
