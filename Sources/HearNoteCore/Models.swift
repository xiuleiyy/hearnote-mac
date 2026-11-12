import Foundation

public struct SegmentTranslation: Codable, Equatable, Sendable {
    public var sourceText: String
    public var text: String
    public var targetLanguage: String

    public init(sourceText: String, text: String, targetLanguage: String) {
        self.sourceText = sourceText
        self.text = text
        self.targetLanguage = targetLanguage
    }
}

public struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var text: String
    public var source: String?
    public var translation: SegmentTranslation?

    public init(
        id: UUID = UUID(), start: Double = 0, end: Double = 0, text: String,
        source: String? = nil, translation: SegmentTranslation? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.source = source
        self.translation = translation
    }

    /// 对照只使用与当前原文完全匹配的译文；旧结果仍需由调用方在修订时清除。
    public var validTranslation: SegmentTranslation? {
        guard let translation, translation.sourceText == text,
              !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return translation
    }
}

public enum SourceKind: String, Codable, Equatable, Sendable {
    case audio, video, recording, text, sample

    public var label: String {
        switch self {
        case .audio: return "音频"
        case .video: return "视频"
        case .recording: return "录音"
        case .text: return "文字"
        case .sample: return "示例"
        }
    }
}

public struct NoteDocument: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var mediaFilename: String?
    public var duration: Double
    public var segments: [TranscriptSegment]
    public var summary: String
    public var translation: String
    public var translationLanguage: String
    public var isFavorite: Bool
    public var sourceKind: SourceKind

    public init(
        id: UUID = UUID(),
        title: String = "未命名笔记",
        createdAt: Date = Date(),
        mediaFilename: String? = nil,
        duration: Double = 0,
        segments: [TranscriptSegment] = [],
        summary: String = "",
        translation: String = "",
        translationLanguage: String = "英文",
        isFavorite: Bool = false,
        sourceKind: SourceKind = .text
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.mediaFilename = mediaFilename
        self.duration = duration
        self.segments = segments
        self.summary = summary
        self.translation = translation
        self.translationLanguage = translationLanguage
        self.isFavorite = isFavorite
        self.sourceKind = sourceKind
    }

    public var plainText: String {
        segments.map(\.text).joined(separator: "\n\n")
    }
}

public struct BedrockConfiguration: Codable, Equatable, Sendable {
    public var region: String
    public var modelID: String

    public init(region: String = "us-east-1", modelID: String = "") {
        self.region = region
        self.modelID = modelID
    }

    /// The region only becomes a subdomain of a fixed AWS domain.
    /// Model IDs remain opaque: no prefix, date, or model name is inferred.
    public var isConfigured: Bool {
        region.range(of: #"^[a-z]{2}(?:-[a-z]+)+-[0-9]+$"#, options: .regularExpression) != nil
            && modelID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,2047}$"#, options: .regularExpression) != nil
    }

    public var endpointHost: String {
        let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        return "bedrock-runtime.\(region).\(suffix)"
    }
}

public enum SampleData {
    public static var document: NoteDocument {
        NoteDocument(
            id: UUID(uuidString: "D8D58147-E77D-4E3A-B144-884970F58DA1")!,
            title: "产品讨论 · 示例笔记",
            duration: 64,
            segments: [
                TranscriptSegment(start: 0, end: 10, text: "今天我们讨论一款 Mac 上的音视频笔记 App。目标是把录音整理成可以阅读、检索和分享的文字。"),
                TranscriptSegment(start: 10, end: 22, text: "第一版先做好四件事：语音转文字、文字翻译、AI 摘要和录音。用户也可以直接导入音视频文件。"),
                TranscriptSegment(start: 22, end: 36, text: "翻译和摘要使用用户自己的 Bedrock API key。第一次打开软件时填写 Region 和模型 ID，密钥保存在 Mac 的钥匙串里。"),
                TranscriptSegment(start: 36, end: 48, text: "转写完成后，用户可以校对原文，点击时间戳回听，也能导出文本、字幕和 Markdown。"),
                TranscriptSegment(start: 48, end: 64, text: "下一个步骤是在真实 Mac 上核验麦克风权限和语音识别。谁负责这项工作、什么时候完成，今天还没有确定。")
            ],
            summary: """
            ## 概要

            讨论一款 Mac 音视频笔记 App 的首版范围。以下内容为内置示例，未调用 Bedrock。

            ## 重点

            - 首版包含转写、翻译、摘要和录音。[00:10]
            - 翻译和摘要使用用户填写的 Bedrock 配置。[00:22]
            - 支持校对、回听和导出。[00:36]

            ## 待办

            - 在真实 Mac 上验证麦克风与语音识别。负责人、截止时间未明确。[00:48]
            """,
            translation: "",
            sourceKind: .sample
        )
    }
}
