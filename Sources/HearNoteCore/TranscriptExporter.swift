import Foundation

public enum TranscriptExporter {
    public static func text(_ document: NoteDocument) -> String {
        document.plainText + "\n"
    }

    public static func srt(_ document: NoteDocument) -> String {
        let ordered = document.segments.enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let left = sanitizedTime($0.element.start)
                let right = sanitizedTime($1.element.start)
                return left == right ? $0.offset < $1.offset : left < right
            }
        return ordered.enumerated().map { index, value in
            let segment = value.element
            let start = sanitizedTime(segment.start)
            let end = max(start + 0.001, sanitizedTime(segment.end))
            let content = segment.text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .joined(separator: "\r\n")
            return "\(index + 1)\r\n\(srtTime(start)) --> \(srtTime(end))\r\n\(content)\r\n"
        }.joined(separator: "\r\n")
    }

    public static func markdown(_ document: NoteDocument) -> String {
        let formatter = ISO8601DateFormatter()
        var output = "# \(document.title.replacingOccurrences(of: "\n", with: " "))\n\n"
        output += "创建时间：\(formatter.string(from: document.createdAt))  \n"
        output += "来源：\(document.sourceKind.label)\n\n"
        if !document.summary.isEmpty {
            output += "## 摘要与待办\n\n\(document.summary)\n\n"
        }
        output += "## 原文\n\n"
        for segment in document.segments {
            let source = segment.source.map { "〔\($0)〕 " } ?? ""
            output += "**[\(displayTime(segment.start))]** \(source)\(segment.text)\n\n"
        }
        if !document.translation.isEmpty {
            output += "## 译文（\(document.translationLanguage)）\n\n\(document.translation)\n"
        }
        return output
    }

    public static func json(_ document: NoteDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    public static func displayTime(_ seconds: Double) -> String {
        let rounded = Int(sanitizedTime(seconds).rounded(.down))
        if rounded >= 3600 {
            return String(format: "%02d:%02d:%02d", rounded / 3600, (rounded / 60) % 60, rounded % 60)
        }
        return String(format: "%02d:%02d", rounded / 60, rounded % 60)
    }

    private static func sanitizedTime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        // Bound before integer conversion to avoid malformed imported data crashing export.
        return min(max(0, seconds), 359_999_999)
    }

    private static func srtTime(_ seconds: Double) -> String {
        let milliseconds = Int((sanitizedTime(seconds) * 1000).rounded())
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1000) % 60,
            milliseconds % 1000
        )
    }
}
