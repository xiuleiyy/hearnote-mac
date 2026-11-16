import Foundation

/// Each Apple input stream records the PCM it actually submitted. Only complete,
/// known digital silence can disqualify text; this is not a speech/noise detector.
public struct AppleSpeechAudioEvidence: Sendable {
    public enum Content: Equatable, Sendable {
        case exactlyZero
        case nonzero
        case unknown
    }

    private struct Interval: Sendable {
        var start: Double
        var end: Double
        let content: Content
    }

    private var intervals: [Interval] = []
    private var forgottenThrough = -Double.infinity
    private let maximumIntervals: Int
    // AnalyzerInput uses a nanosecond timescale. Accommodate only representation
    // rounding, far below one PCM sample, rather than treating audio gaps as zero.
    private static let timeTolerance = 0.000_000_001

    public private(set) var rejectedZeroResultCount = 0

    public init(maximumIntervals: Int = 4096) {
        self.maximumIntervals = max(1, maximumIntervals)
    }

    public mutating func record(start: Double, duration: Double, content: Content) {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0,
              (start + duration).isFinite else { return }
        let end = start + duration
        if let last = intervals.last, last.content == content,
           start >= last.start, start <= last.end + Self.timeTolerance {
            intervals[intervals.count - 1].end = max(last.end, end)
        } else {
            intervals.append(Interval(start: start, end: end, content: content))
            // Production timelines are monotonic. Preserve conservative coverage
            // if another caller supplies out-of-order evidence.
            if intervals.count > 1, start < intervals[intervals.count - 2].start {
                intervals.sort { $0.start < $1.start }
            }
        }
        if intervals.count > maximumIntervals {
            // Forgotten history becomes uncovered/unknown, never known silence.
            let count = intervals.count - maximumIntervals
            if let end = intervals.prefix(count).map(\.end).max() {
                forgottenThrough = max(forgottenThrough, end)
            }
            intervals.removeFirst(count)
        }
    }

    public func isConfirmedSilence(start: Double, end: Double) -> Bool {
        guard start.isFinite, end.isFinite, start >= 0, end >= start,
              start >= forgottenThrough else { return false }
        if start == end {
            let covering = intervals.filter { $0.start <= start && start < $0.end }
            return !covering.isEmpty && covering.allSatisfy { $0.content == .exactlyZero }
        }
        let covering = intervals.filter { $0.start < end && $0.end > start }
        guard !covering.isEmpty, covering.allSatisfy({ $0.content == .exactlyZero }) else {
            return false
        }
        var coveredThrough = start
        for interval in covering {
            guard interval.start <= coveredThrough + Self.timeTolerance else { return false }
            coveredThrough = max(coveredThrough, interval.end)
        }
        return coveredThrough + Self.timeTolerance >= end
    }

    /// Empty revisions and finalization watermarks must still reach the mapper.
    public mutating func accepts(text: String, start: Double, end: Double) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isConfirmedSilence(start: start, end: end) else { return true }
        if rejectedZeroResultCount < Int.max { rejectedZeroResultCount += 1 }
        return false
    }

    /// Recheck mapper output against the PCM now submitted, including a pending
    /// result promoted by a watermark or successful finish. Retraction preserves
    /// the original UUID, source, range and finalization state.
    public mutating func validate(
        _ update: AppleSpeechResultMapper.Update
    ) -> AppleSpeechResultMapper.Update {
        let original = update.segment
        guard !accepts(text: original.text, start: original.start, end: original.end) else {
            return update
        }
        var retracted = original
        retracted.text = ""
        return AppleSpeechResultMapper.Update(segment: retracted, isFinal: update.isFinal)
    }
}
