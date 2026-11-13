import Foundation

public enum AppleSpeechAssetStatus: String, Sendable {
    case unsupported, downloading, supported, installed
}

public enum AppleSpeechPreparationStage: String, Sendable {
    case checkingAssets
    case checkingInstalledLocales
    case preparingExistingAssets
    case requestingInstallation
    case installingAssets
    case checkingAssetsAfterInstallation
    case checkingAssetsAfterPreparation
    case loadingAssets
    case choosingAudioFormat
    case preparingAudioFormat
    case startingAnalyzer
}

public enum AppleSpeechAssetPreparationError: Error, Equatable {
    case unsupportedAssets
}

/// 独立于 Speech SDK 的资产准备流程。资产状态用于诊断，实际加载成功才算准备完成。
/// 每个识别来源独立调用；不保存共享状态，也不清理系统资产或其他来源的安装请求。
@MainActor
public enum AppleSpeechAssetPreparation {
    public struct Event: Equatable, Sendable {
        public let stage: AppleSpeechPreparationStage
        public let initialStatus: AppleSpeechAssetStatus?
        public let observedStatus: AppleSpeechAssetStatus?
        /// true 表示创建了安装请求，false 表示系统返回 nil，nil 表示尚未请求。
        public let installationRequested: Bool?
        public let hasInstalledLocale: Bool?

        public init(
            stage: AppleSpeechPreparationStage,
            initialStatus: AppleSpeechAssetStatus? = nil,
            observedStatus: AppleSpeechAssetStatus? = nil,
            installationRequested: Bool? = nil,
            hasInstalledLocale: Bool? = nil
        ) {
            self.stage = stage
            self.initialStatus = initialStatus
            self.observedStatus = observedStatus
            self.installationRequested = installationRequested
            self.hasInstalledLocale = hasInstalledLocale
        }
    }

    public static func prepare(
        status: () async -> AppleSpeechAssetStatus,
        hasInstalledLocale: () async -> Bool,
        install: () async throws -> Bool,
        prepare: () async throws -> Void,
        checkCancellation: () throws -> Void,
        onEvent: (Event) -> Void
    ) async throws {
        func check() throws {
            try Task.checkCancellation()
            try checkCancellation()
        }

        try check()
        onEvent(Event(stage: .checkingAssets))
        try check()
        let initialStatus = await status()
        try check()
        onEvent(Event(stage: .checkingAssets, initialStatus: initialStatus,
                      observedStatus: initialStatus))

        guard initialStatus != .unsupported else {
            throw AppleSpeechAssetPreparationError.unsupportedAssets
        }

        var localeIsInstalled: Bool?
        if initialStatus != .installed {
            try check()
            onEvent(Event(stage: .checkingInstalledLocales, initialStatus: initialStatus,
                          observedStatus: initialStatus))
            try check()
            localeIsInstalled = await hasInstalledLocale()
            try check()
            onEvent(Event(stage: .checkingInstalledLocales, initialStatus: initialStatus,
                          observedStatus: initialStatus,
                          hasInstalledLocale: localeIsInstalled))
        }

        if initialStatus == .installed || localeIsInstalled == true {
            try check()
            onEvent(Event(stage: .preparingExistingAssets, initialStatus: initialStatus,
                          observedStatus: initialStatus,
                          hasInstalledLocale: localeIsInstalled))
            try check()
            try await prepare()
            try check()
            onEvent(Event(stage: .checkingAssetsAfterPreparation, initialStatus: initialStatus,
                          hasInstalledLocale: localeIsInstalled))
            try check()
            let observedStatus = await status()
            try check()
            onEvent(Event(stage: .checkingAssetsAfterPreparation, initialStatus: initialStatus,
                          observedStatus: observedStatus,
                          hasInstalledLocale: localeIsInstalled))
            return
        }

        try check()
        onEvent(Event(stage: .requestingInstallation, initialStatus: initialStatus,
                      observedStatus: initialStatus, hasInstalledLocale: localeIsInstalled))
        try check()
        let installationRequested = try await install()
        try check()
        onEvent(Event(stage: .checkingAssetsAfterInstallation, initialStatus: initialStatus,
                      installationRequested: installationRequested,
                      hasInstalledLocale: localeIsInstalled))
        try check()
        let observedStatus = await status()
        try check()
        onEvent(Event(stage: .checkingAssetsAfterInstallation, initialStatus: initialStatus,
                      observedStatus: observedStatus,
                      installationRequested: installationRequested,
                      hasInstalledLocale: localeIsInstalled))

        // 安装请求为 nil，或状态仍为 supported，均不能代替真实的加载验证。
        // 加载/安装错误原样传给调用者，保留 NSError 的 domain、code 与 underlying error。
        try check()
        onEvent(Event(stage: .loadingAssets, initialStatus: initialStatus,
                      observedStatus: observedStatus,
                      installationRequested: installationRequested,
                      hasInstalledLocale: localeIsInstalled))
        try check()
        try await prepare()
        try check()
    }

    /// 只归一 Locale 的标准写法；区域和文字体系仍需匹配，避免把 zh-TW 当成 zh-CN。
    public nonisolated static func matchesInstalledLocale(
        requested: Locale,
        installed: [Locale]
    ) -> Bool {
        func normalized(_ locale: Locale) -> String {
            Locale.canonicalIdentifier(from: locale.identifier)
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
        }
        let requestedIdentifier = normalized(requested)
        return installed.contains { normalized($0) == requestedIdentifier }
    }
}
