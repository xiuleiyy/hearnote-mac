import Foundation

/// 只用于新产生的 Whisper 输出，避免技术占位进入正文；不修改已有笔记或导出数据。
public enum WhisperTranscriptCleaner {
    public struct TimedWord: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let text: String

        public init(start: Double, end: Double, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public static func removingBlankAudio(from words: [TimedWord]) -> [TimedWord] {
        // SDK 可把方括号、下划线和字母拆为不同词，甚至跨 segment。
        // 先按原输出顺序匹配，再把删除范围映射回每个词，保留原空格和时间轴。
        let combined = words.map(\.text).joined() as NSString
        var markerRanges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: combined.length)
        while searchRange.length > 0 {
            let match = combined.range(of: "[BLANK_AUDIO]", options: .literal, range: searchRange)
            guard match.location != NSNotFound else { break }
            markerRanges.append(match)
            let next = NSMaxRange(match)
            searchRange = NSRange(location: next, length: combined.length - next)
        }
        guard !markerRanges.isEmpty else { return words }

        var offset = 0
        var cleanedWords: [TimedWord] = []
        var pendingWhitespace = ""
        for word in words {
            let length = (word.text as NSString).length
            let wordRange = NSRange(location: offset, length: length)
            offset += length
            let removals = markerRanges.compactMap { marker -> NSRange? in
                let intersection = NSIntersectionRange(marker, wordRange)
                guard intersection.length > 0 else { return nil }
                return NSRange(location: intersection.location - wordRange.location,
                               length: intersection.length)
            }
            let cleaned = NSMutableString(string: word.text)
            for range in removals.reversed() { cleaned.deleteCharacters(in: range) }
            var text = cleaned as String
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingWhitespace += text
                continue
            }
            // marker 单独占一个词时，它留下的空格仍可能是前后真实词的唯一分隔。
            // 把分隔附到后一个真实词，保留该词的时间，不给占位生成新的时间片段。
            if !pendingWhitespace.isEmpty, let previous = cleanedWords.last,
               previous.text.last?.isWhitespace != true, text.first?.isWhitespace != true {
                text = pendingWhitespace + text
            }
            pendingWhitespace = ""
            cleanedWords.append(TimedWord(start: word.start, end: word.end, text: text))
        }
        return cleanedWords
    }
}
