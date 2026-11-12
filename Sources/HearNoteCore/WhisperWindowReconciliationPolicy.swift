import Foundation

/// 处理重叠窗时间戳漂移和明显的内部漏段，只合并模型曾实际给出的原词与原时间。
/// 不补参考答案，不保留正常撤回的尾词，不把已有文字当作声学准确性的证明。
public struct WhisperWindowReconciliationPolicy {
    public typealias TimedWord = WhisperTranscriptCleaner.TimedWord

    public struct Snapshot: Equatable, Sendable {
        public let words: [TimedWord]
        public let followingWord: TimedWord?
        public let requiresConfirmation: Bool
        public let retainedInteriorWords: Bool
    }

    private var previouslyPublished: [TimedWord] = []
    private var confirmedSnapshotStart: Double?
    private var confirmedSnapshotEnd: Double?
    private let minimumOmissionDuration: Double
    private let minimumOmissionWords: Int

    public init(minimumOmissionDuration: Double = 2, minimumOmissionWords: Int = 3) {
        self.minimumOmissionDuration = minimumOmissionDuration.isFinite
            ? max(0.5, minimumOmissionDuration) : 2
        self.minimumOmissionWords = max(2, minimumOmissionWords)
    }

    /// first pass 的明显内部回退先要求一次复核；confirmed pass 才允许保留旧模型原词。
    /// 调用方每个快照最多调用一次额外模型请求；本 policy 本身不调模型。
    public mutating func reconcile(
        words: [TimedWord], coreStart: Double, publicationEnd: Double, audioEnd: Double,
        confirmed: Bool = false
    ) -> Snapshot {
        guard coreStart.isFinite, publicationEnd.isFinite, audioEnd.isFinite,
              publicationEnd >= coreStart, audioEnd >= publicationEnd else {
            return Snapshot(words: [], followingWord: nil, requiresConfirmation: false,
                            retainedInteriorWords: false)
        }
        let usable = words.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.start < $1.start }
        let oldBody = previouslyPublished.filter {
            midpoint($0) >= coreStart && midpoint($0) < publicationEnd
        }
        var body = usable.filter { midpoint($0) >= coreStart && midpoint($0) < publicationEnd }
        // 上一快照已归属当前核心的词，小幅修订后落在左侧重叠窗，不能先裁掉再
        // 由 replacingFrom 清除旧版本。使用其先前真实时间维持归属，不制造新时间。
        for old in oldBody where !body.contains(where: { sameWord($0, old) }) {
            if usable.contains(where: {
                midpoint($0) < coreStart && coreStart - midpoint($0) <= 0.5 && sameWord($0, old)
            }) {
                body.append(old)
            }
        }
        body.sort { $0.start < $1.start }
        let omitted = interiorOmissions(previous: oldBody, current: body)
        let alreadyConfirmed = confirmedSnapshotStart == coreStart && confirmedSnapshotEnd == audioEnd
        if !omitted.isEmpty, !confirmed, !alreadyConfirmed {
            // 不提交第一次明显回退，也不改写 previous baseline。
            // 静音调度可能重用同一份 PCM；该快照不能反复增加确认请求。
            confirmedSnapshotStart = coreStart
            confirmedSnapshotEnd = audioEnd
            return Snapshot(
                words: body, followingWord: usable.first { midpoint($0) >= publicationEnd },
                requiresConfirmation: true, retainedInteriorWords: false
            )
        }
        for old in omitted where !body.contains(where: { overlaps($0, old) || sameWord($0, old) }) {
            body.append(old)
        }
        body.sort { $0.start < $1.start }
        previouslyPublished = previouslyPublished.filter {
            midpoint($0) >= publicationEnd && $0.start <= audioEnd
        } + body
        // 实时窗口至多18秒、文件窗口至多30秒；只留重叠范围，不随会议累积。
        previouslyPublished.removeAll { $0.end < coreStart - 3 }
        return Snapshot(
            words: body, followingWord: usable.first { midpoint($0) >= publicationEnd },
            requiresConfirmation: false, retainedInteriorWords: !omitted.isEmpty
        )
    }

    private func interiorOmissions(previous: [TimedWord], current: [TimedWord]) -> [TimedWord] {
        guard let first = current.first, let last = current.last else { return [] }
        // 必须有真实的新结果在两边继续覆盖；整段空结果和被撤回的尾部不做保留。
        let missing = previous.filter { old in
            old.start >= first.end && old.end <= last.start
                && !current.contains { overlaps($0, old) || sameWord($0, old) }
        }
        var groups: [[TimedWord]] = []
        for word in missing {
            if let last = groups.last?.last, word.start - last.end <= 1,
               !current.contains(where: { $0.start >= last.end && $0.end <= word.start }),
               let index = groups.indices.last {
                groups[index].append(word)
            } else { groups.append([word]) }
        }
        return groups.filter {
            $0.count >= minimumOmissionWords
                && ($0.last!.end - $0.first!.start) >= minimumOmissionDuration
        }.flatMap { $0 }
    }

    private func midpoint(_ word: TimedWord) -> Double { (word.start + word.end) / 2 }

    private func sameWord(_ lhs: TimedWord, _ rhs: TimedWord) -> Bool {
        lhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            == rhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            && abs(midpoint(lhs) - midpoint(rhs)) <= 0.5
    }

    private func overlaps(_ lhs: TimedWord, _ rhs: TimedWord) -> Bool {
        let shorter = min(lhs.end - lhs.start, rhs.end - rhs.start)
        let overlap = min(lhs.end, rhs.end) - max(lhs.start, rhs.start)
        return shorter > 0 ? overlap >= shorter * 0.5
            : abs(midpoint(lhs) - midpoint(rhs)) <= 0.05
    }
}
