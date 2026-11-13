import Foundation

/// 只依据实际错误类型决定恢复方式，不用单段输出错误推断网络或凭据故障。
public enum LiveTranslationFailurePolicy {
    public enum Category: String, Equatable {
        case authentication, configuration, rateLimited, network, service
        case languageRule, modelContent, unknown
    }

    public enum Recovery: Equatable {
        case retry(after: TimeInterval)
        case retryManually
        case pause
    }

    public struct Failure: Equatable {
        public let category: Category
        public let recovery: Recovery
        public let message: String
        public let attempts: Int
    }

    /// 每版原文最多两次自动调用。手动重试或原文修订可以开始新的有界尝试。
    public static let maximumAutomaticAttempts = 2

    public static func failure(for error: Error, attempts: Int) -> Failure {
        let category: Category
        let message: String
        let pause: Bool
        let delay: TimeInterval?
        if let error = error as? BedrockError {
            message = error.localizedDescription
            switch error {
            case .invalidAPIKey, .httpFailure(401), .httpFailure(403):
                category = .authentication; pause = true; delay = nil
            case .invalidConfiguration, .invalidLanguage, .invalidGlossary,
                 .httpFailure(400), .httpFailure(404):
                category = .configuration; pause = true; delay = nil
            case .httpFailure(300...399):
                category = .configuration; pause = true; delay = nil
            case .httpFailure(429), .throttled:
                category = .rateLimited; pause = false; delay = 5
            case .httpFailure(408), .httpFailure(504):
                category = .service; pause = false; delay = 2
            case .httpFailure(500...599):
                category = .service; pause = false; delay = 2
            case .untranslatedInput:
                category = .languageRule; pause = false; delay = 1
            case .invalidResponse, .outputTruncated, .unexpectedStop:
                category = .modelContent; pause = false; delay = 1
            case .contentFiltered, .emptyInput, .inputTooLong:
                category = .modelContent; pause = false; delay = nil
            case .httpFailure:
                category = .unknown; pause = false; delay = nil
            }
        } else if let error = error as? URLError {
            category = error.code == .cancelled ? .unknown : .network
            if error.code == .cancelled {
                message = "本段翻译请求已取消，未保存译文。可重试此段。"
            } else {
                message = error.code == .timedOut
                    ? "翻译请求超时，本段没有保存译文。"
                    : "翻译请求未能完成网络传输（\(error.code.rawValue)），本段没有保存译文。"
            }
            pause = false
            delay = error.code == .cancelled ? nil : 2
        } else {
            category = .unknown
            message = "本段翻译失败，未保存译文。请重试此段。"
            pause = false
            delay = nil
        }
        let recovery: Recovery
        if pause { recovery = .pause }
        else if let delay, attempts < maximumAutomaticAttempts { recovery = .retry(after: delay) }
        else { recovery = .retryManually }
        return Failure(category: category, recovery: recovery, message: message, attempts: attempts)
    }
}
