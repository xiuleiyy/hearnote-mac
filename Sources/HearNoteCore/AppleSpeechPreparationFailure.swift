import Foundation

/// Keeps the original error for inspection while providing a bounded, private-data-free diagnostic.
/// Callers should rethrow cancellation instead of presenting it as a preparation failure.
public struct AppleSpeechPreparationFailure: LocalizedError, CustomNSError,
    CustomStringConvertible, CustomDebugStringConvertible {
    public let stage: AppleSpeechPreparationStage
    public let underlyingError: Error

    private let diagnostic: Diagnostic

    public init(stage: AppleSpeechPreparationStage, underlyingError: Error) {
        self.stage = stage
        self.underlyingError = underlyingError
        self.diagnostic = Self.inspect(underlyingError as NSError)
    }

    /// A convenience for callers that receive a cancellation through an untyped catch.
    public static func wrapping(
        stage: AppleSpeechPreparationStage, underlyingError: Error
    ) -> Error {
        if underlyingError is CancellationError { return underlyingError }
        return Self(stage: stage, underlyingError: underlyingError)
    }

    public var isServiceConnectionFailure: Bool { diagnostic.connectionCode != nil }

    public var diagnosticSummary: String {
        var summary = "阶段：\(stageLabel)（\(stage.rawValue)）；错误链："
            + diagnostic.errors.map { "\($0.domain) \($0.code)" }.joined(separator: " → ")
        if diagnostic.truncated { summary += "；诊断链已截断" }
        if diagnostic.repeatedNode { summary += "；重复错误节点已省略" }
        return summary
    }

    public var errorDescription: String? {
        let detail: String
        if let code = diagnostic.connectionCode {
            detail = "Apple 识别服务连接失败（阶段：\(stageLabel)；NSCocoaErrorDomain \(code)）。"
        } else {
            detail = "Apple 语音识别准备失败（阶段：\(stageLabel)）。"
        }
        return detail + "录音仍保存在本机，可稍后重试或使用本地 Whisper。"
    }

    public var description: String { diagnosticSummary }
    public var debugDescription: String { diagnosticSummary }

    public static var errorDomain: String { "app.hearnote.apple-speech-preparation" }
    public var errorCode: Int { 1 }
    public var errorUserInfo: [String: Any] {
        [
            NSLocalizedDescriptionKey: errorDescription ?? "Apple 语音识别准备失败。",
            NSUnderlyingErrorKey: underlyingError as NSError
        ]
    }

    private var stageLabel: String {
        switch stage {
        case .checkingAssets: return "检查识别资产"
        case .checkingInstalledLocales: return "检查已安装语种"
        case .preparingExistingAssets: return "加载已有识别资产"
        case .requestingInstallation: return "请求安装识别资产"
        case .installingAssets: return "下载并安装识别资产"
        case .checkingAssetsAfterInstallation: return "检查安装后的识别资产"
        case .checkingAssetsAfterPreparation: return "检查加载后的识别资产"
        case .loadingAssets: return "加载识别资产"
        case .choosingAudioFormat: return "选择音频格式"
        case .preparingAudioFormat: return "准备音频格式"
        case .startingAnalyzer: return "启动语音分析"
        }
    }

    private struct ErrorCode {
        let domain: String
        let code: Int
    }

    private struct Diagnostic {
        var errors: [ErrorCode] = []
        var connectionCode: Int?
        var truncated = false
        var repeatedNode = false
    }

    private static let maximumDepth = 8
    private static let maximumNodes = 12
    private static let allowedDomains: Set<String> = [
        NSCocoaErrorDomain, NSOSStatusErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain,
        "kAFAssistantErrorDomain", "SFSpeechErrorDomain", "kLSRErrorDomain",
        errorDomain
    ]
    #if os(macOS)
    private static let multipleUnderlyingErrorsKey = NSMultipleUnderlyingErrorsKey
    #else
    // This Foundation key is not exported by older swift-corelibs-foundation toolchains.
    private static let multipleUnderlyingErrorsKey = "NSMultipleUnderlyingErrors"
    #endif

    private static func inspect(_ root: NSError) -> Diagnostic {
        var diagnostic = Diagnostic()
        var pending: [(error: NSError, depth: Int)] = [(root, 0)]
        var visited = Set<ObjectIdentifier>()

        while let node = pending.popLast() {
            let identity = ObjectIdentifier(node.error)
            guard !visited.contains(identity) else {
                diagnostic.repeatedNode = true
                continue
            }
            guard node.depth < maximumDepth, visited.count < maximumNodes else {
                diagnostic.truncated = true
                continue
            }
            visited.insert(identity)
            let domain = node.error.domain
            let code = node.error.code
            diagnostic.errors.append(ErrorCode(
                domain: allowedDomains.contains(domain) ? domain : "redacted-domain", code: code
            ))
            if diagnostic.connectionCode == nil, domain == NSCocoaErrorDomain,
               code == CocoaError.Code.xpcConnectionInterrupted.rawValue ||
               code == CocoaError.Code.xpcConnectionInvalid.rawValue {
                diagnostic.connectionCode = code
            }

            // Read only the two documented error links; never render arbitrary userInfo.
            let information = node.error.userInfo
            var children: [NSError] = []
            if let underlying = information[NSUnderlyingErrorKey] as? Error {
                children.append(underlying as NSError)
            }
            if let underlying = information[multipleUnderlyingErrorsKey] as? NSArray {
                let count = min(underlying.count, maximumNodes)
                if underlying.count > count { diagnostic.truncated = true }
                for index in 0..<count {
                    if let error = underlying[index] as? Error {
                        children.append(error as NSError)
                    }
                }
            }
            for child in children.reversed() {
                pending.append((child, node.depth + 1))
            }
        }
        return diagnostic
    }
}
