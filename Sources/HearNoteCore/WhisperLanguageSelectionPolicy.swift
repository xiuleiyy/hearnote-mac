import Foundation

/// 明确语种固定；中英混合只在完全相同的音频快照确认时复用语言选择。
/// 新 PCM 或新核心窗口仍重新检测，允许真正的语言切换，不猜测语言置信度。
public struct WhisperLanguageSelectionPolicy {
    public let fixedLanguage: String?
    public let restrictToChineseEnglish: Bool
    private var snapshotStart: Double?
    private var snapshotEnd: Double?
    private var selectedLanguage: String?

    public init(locale: String) {
        let normalized = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        restrictToChineseEnglish = normalized == "zh-en"
        let language = normalized.split(separator: "-").first.map(String.init)
        fixedLanguage = !restrictToChineseEnglish && language.map {
            ["zh", "en", "ja", "ko", "fr", "de", "es"].contains($0)
        } == true ? language : nil
    }

    public mutating func language(coreStart: Double, audioEnd: Double) -> String? {
        if let fixedLanguage { return fixedLanguage }
        guard restrictToChineseEnglish, coreStart.isFinite, audioEnd.isFinite else { return nil }
        if snapshotStart != coreStart || snapshotEnd != audioEnd {
            snapshotStart = coreStart
            snapshotEnd = audioEnd
            selectedLanguage = nil
        }
        return selectedLanguage
    }

    public mutating func observe(language: String?, coreStart: Double, audioEnd: Double) {
        guard restrictToChineseEnglish, snapshotStart == coreStart, snapshotEnd == audioEnd,
              selectedLanguage == nil, let language, ["zh", "en"].contains(language) else { return }
        selectedLanguage = language
    }
}
