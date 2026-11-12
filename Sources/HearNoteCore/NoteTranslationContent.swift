import Foundation

/// 只读取已有有效译文；不会发起翻译、写回正文或改动旧笔记。
public struct NoteTranslationContent: Equatable, Sendable {
    public let savedText: String?
    public let translatedSegments: [TranscriptSegment]
    public let sourceSegmentCount: Int

    public var hasContent: Bool {
        savedText != nil || !translatedSegments.isEmpty
    }

    /// 仅统计缺少有效逐段译文的片段；有全文译文时不能据此判断全文覆盖情况。
    public var untranslatedSegmentCount: Int {
        max(0, sourceSegmentCount - translatedSegments.count)
    }

    fileprivate init(
        savedText: String?,
        translatedSegments: [TranscriptSegment],
        sourceSegmentCount: Int
    ) {
        self.savedText = savedText
        self.translatedSegments = translatedSegments
        self.sourceSegmentCount = sourceSegmentCount
    }
}

public extension NoteDocument {
    var hasTranscriptText: Bool {
        segments.contains {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var translationContent: NoteTranslationContent {
        let sourceSegments = segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return NoteTranslationContent(
            savedText: translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : translation,
            translatedSegments: sourceSegments.filter { $0.validTranslation != nil },
            sourceSegmentCount: sourceSegments.count
        )
    }
}
