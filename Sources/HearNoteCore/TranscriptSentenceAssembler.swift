import Foundation

/// 把可修订的识别窗口整理成句子，不改写模型产生的词。
/// 每个声音来源独立持有一份；完成句封存，只有未完成的尾句会继续增补。
public struct TranscriptSentenceAssembler {
    public typealias TimedWord = WhisperTranscriptCleaner.TimedWord

    public struct Update: Equatable, Sendable {
        public let segment: TranscriptSegment
        public let isFinal: Bool
    }

    private struct PendingSentence {
        let segment: TranscriptSegment
    }

    private let pauseInterval: Double
    private let maximumDuration: Double
    private let maximumCharacters: Int
    private var pendingWords: [TimedWord] = []
    private var pendingSentences: [PendingSentence] = []
    private var sealedMidpoint = -Double.infinity
    private var sealedWords: [TimedWord] = []

    public init(pauseInterval: Double = 0.8, maximumDuration: Double = 10,
                maximumCharacters: Int = 240) {
        self.pauseInterval = pauseInterval.isFinite ? max(0.1, pauseInterval) : 0.8
        self.maximumDuration = maximumDuration.isFinite ? max(1, maximumDuration) : 10
        self.maximumCharacters = max(20, maximumCharacters)
    }

    public var hasPendingSentence: Bool { !pendingWords.isEmpty }

    /// 所有时间使用同一条绝对时间轴。replacingFrom 之前的未完句保留；
    /// stableThrough 是已完成解码窗口的稳定范围；部分结果的标点及尾静音须先确认前缀稳定。
    /// followingWord 提供核心窗口之外的上下文，trailingSilenceFrom 只接受实际音频静音证据。
    public mutating func update(
        words: [TimedWord], replacingFrom: Double, observedThrough: Double,
        stableThrough: Double = -Double.infinity, followingWord: TimedWord? = nil,
        trailingSilenceFrom: Double? = nil, source: String? = nil, finishing: Bool = false
    ) -> [Update] {
        guard replacingFrom.isFinite, observedThrough.isFinite else { return [] }
        let previousWords = pendingWords
        let usableWords = words.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && midpoint($0) >= replacingFrom
                && (belongsToPendingWord($0, previousWords: previousWords)
                    || (midpoint($0) > sealedMidpoint && !overlapsSealedWord($0)))
        }.sorted { $0.start < $1.start }
        pendingWords = pendingWords.filter {
            midpoint($0) < replacingFrom
        } + usableWords

        let groups = sentenceGroups(
            pendingWords, previousWords: previousWords, observedThrough: observedThrough,
            stableThrough: stableThrough, followingWord: followingWord,
            trailingSilenceFrom: trailingSilenceFrom, finishing: finishing
        )
        var usedIDs = Set<UUID>()
        var result: [Update] = []
        var nextPending: [PendingSentence] = []
        for group in groups {
            guard let first = group.words.first, let last = group.words.last else { continue }
            // 同一个未完句跨解码窗口、时间戳轻微修订时继续用同一个 UUID。
            let previous = pendingSentences.filter {
                !usedIDs.contains($0.segment.id)
                    && abs($0.segment.start - first.start) <= 1
            }.min { abs($0.segment.start - first.start) < abs($1.segment.start - first.start) }
            let id = previous?.segment.id ?? UUID()
            usedIDs.insert(id)
            let segment = TranscriptSegment(
                id: id, start: first.start, end: max(first.start + 0.01, last.end),
                text: group.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                source: source
            )
            if group.isFinal || previous?.segment != segment {
                result.append(Update(segment: segment, isFinal: group.isFinal))
            }
            if group.isFinal {
                sealedMidpoint = max(sealedMidpoint, midpoint(last))
                sealedWords.append(contentsOf: group.words)
                // 仅重叠窗口附近的归属需要保留，不把整场词表留在内存。
                sealedWords = Array(sealedWords.suffix(32))
            } else {
                nextPending.append(PendingSentence(segment: segment))
            }
        }
        // 最新快照撤回临时幻觉时，明确删除旧尾句；从不删除已经完成的句子。
        for previous in pendingSentences where !usedIDs.contains(previous.segment.id) {
            var removed = previous.segment
            removed.text = ""
            result.append(Update(segment: removed, isFinal: false))
        }
        pendingSentences = nextPending
        pendingWords = groups.filter { !$0.isFinal }.flatMap(\.words)
        return result
    }

    /// 无新增快照时结束尾句；例如 epoch 尾部已没有待解码音频。
    public mutating func finish(source: String? = nil) -> [Update] {
        guard let first = pendingWords.first else { return [] }
        return update(words: pendingWords, replacingFrom: first.start,
                      observedThrough: pendingWords.last?.end ?? first.end,
                      source: source, finishing: true)
    }

    private struct Group {
        let words: [TimedWord]
        let isFinal: Bool
    }

    private func sentenceGroups(
        _ words: [TimedWord], previousWords: [TimedWord], observedThrough: Double,
        stableThrough: Double, followingWord: TimedWord?, trailingSilenceFrom: Double?,
        finishing: Bool
    ) -> [Group] {
        var result: [Group] = []
        var current: [TimedWord] = []
        var characterCount = 0
        for (index, word) in words.enumerated() {
            if let previous = current.last, word.start - previous.end >= pauseInterval,
               isStable(current, previousWords: previousWords, through: stableThrough) {
                result.append(Group(words: current, isFinal: true))
                current = []
                characterCount = 0
            }
            current.append(word)
            characterCount += word.text.count
            let next = index + 1 < words.count ? words[index + 1] : followingWord
            let hasFollowingAudio = next != nil || observedThrough - word.end >= 0.35
            let bounded = word.end - (current.first?.start ?? word.start) >= maximumDuration
                || characterCount >= maximumCharacters
            if hasFollowingAudio && (isSentenceEnding(word.text, next: next?.text) || bounded)
                && isStable(current, previousWords: previousWords, through: stableThrough) {
                result.append(Group(words: current, isFinal: true))
                current = []
                characterCount = 0
            }
        }
        if let last = current.last {
            let actualTrailingPause = trailingSilenceFrom.map {
                followingWord == nil && $0.isFinite && observedThrough - $0 + 1e-9 >= pauseInterval
                    && last.end <= $0 + 0.25
                    && isStable(current, previousWords: previousWords, through: stableThrough)
            } ?? false
            let followingPause = followingWord.map {
                $0.start - last.end >= pauseInterval
                    && isStable(current, previousWords: previousWords, through: stableThrough)
            } ?? false
            result.append(Group(
                words: current,
                isFinal: finishing || actualTrailingPause || followingPause
            ))
        }
        return result
    }

    private func isStable(_ words: [TimedWord], previousWords: [TimedWord], through: Double) -> Bool {
        guard let first = words.first, let last = words.last else { return false }
        if midpoint(last) < through { return true }
        guard let index = previousWords.firstIndex(where: {
            abs($0.start - first.start) <= 0.5 && $0.text == first.text
        }), previousWords.count - index >= words.count else { return false }
        return zip(words, previousWords[index..<(index + words.count)]).allSatisfy {
            $0.text == $1.text && abs($0.start - $1.start) <= 0.5 && abs($0.end - $1.end) <= 0.5
        }
    }

    private func isSentenceEnding(_ text: String, next: String?) -> Bool {
        let closing = CharacterSet(charactersIn: "\"'”’」』）》)]}")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: closing)
        guard let last = trimmed.last else { return false }
        if "。！？!?".contains(last) { return true }
        guard last == ".", !trimmed.hasSuffix("..") else { return false }
        let token = trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init)?.lowercased() ?? ""
        let abbreviations: Set<String> = [
            "mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.",
            "e.g.", "i.e.", "etc.", "u.s.", "u.k.", "a.m.", "p.m."
        ]
        if abbreviations.contains(token) { return false }
        if token.count == 2, token.first?.isLetter == true { return false }
        // 小数点或网址被 tokenizer 拆开时，不把中间的点当句号。
        if let next, next.first?.isWhitespace != true {
            let nextTrimmed = next.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.dropLast().allSatisfy(\.isNumber), nextTrimmed.first?.isNumber == true {
                return false
            }
            if nextTrimmed.first?.isLowercase == true { return false }
        }
        return true
    }

    private func midpoint(_ word: TimedWord) -> Double { (word.start + word.end) / 2 }

    private func overlapsSealedWord(_ word: TimedWord) -> Bool {
        let duration = word.end - word.start
        return sealedWords.contains { sealed in
            let overlap = min(word.end, sealed.end) - max(word.start, sealed.start)
            if duration > 0 {
                // 已完成尾词的小幅时间戳修订仍归属旧句；真正下一词的轻微边缘
                // 重叠不超过自身一半，继续接受，避免把合法续词一起吞掉。
                return overlap > 0 && overlap / duration >= 0.5
            }
            return word.start >= sealed.start && word.start <= sealed.end
        }
    }

    private func belongsToPendingWord(_ word: TimedWord, previousWords: [TimedWord]) -> Bool {
        previousWords.contains {
            // 已明确显示为未完句的词保留自身归属，不能因为邻接词时间戳重叠而
            // 在下一快照突然撤回；同一时间范围的文字修订也仍属于这句。
            ($0.text == word.text && abs(midpoint($0) - midpoint(word)) <= 0.5)
                || (abs($0.start - word.start) <= 0.15 && abs($0.end - word.end) <= 0.15)
        }
    }
}
