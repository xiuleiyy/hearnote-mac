import Foundation
import XCTest
@testable import HearNoteCore

final class AppleSpeechPreparationFailureTests: XCTestCase {
    func testOriginalNSErrorAndUnderlyingChainRetainTheirIdentity() throws {
        let inner = NSError(domain: NSCocoaErrorDomain, code: 4099)
        let original = NSError(
            domain: "SFSpeechErrorDomain", code: 7, userInfo: [NSUnderlyingErrorKey: inner]
        )
        let failure = AppleSpeechPreparationFailure(
            stage: .loadingAssets, underlyingError: original
        )

        XCTAssertTrue((failure.underlyingError as NSError) === original)
        XCTAssertTrue(try XCTUnwrap(failure.errorUserInfo[NSUnderlyingErrorKey] as? NSError) === original)
        let bridged = failure as NSError
        let preserved = try XCTUnwrap(bridged.userInfo[NSUnderlyingErrorKey] as? NSError)
        XCTAssertTrue(preserved === original)
        XCTAssertTrue(try XCTUnwrap(preserved.userInfo[NSUnderlyingErrorKey] as? NSError) === inner)
        XCTAssertTrue(failure.isServiceConnectionFailure)
        XCTAssertTrue(failure.diagnosticSummary.contains("SFSpeechErrorDomain 7 → NSCocoaErrorDomain 4099"))
        XCTAssertTrue(bridged.localizedDescription.contains("Apple 识别服务连接失败"))
    }

    func testSwiftErrorRemainsAvailableWithoutConvertingItToATextMessage() {
        enum TestError: Error, Equatable { case assetPreparation }
        let failure = AppleSpeechPreparationFailure(
            stage: .preparingExistingAssets, underlyingError: TestError.assetPreparation
        )
        XCTAssertEqual(failure.underlyingError as? TestError, .assetPreparation)
        XCTAssertNotNil(failure.errorUserInfo[NSUnderlyingErrorKey] as? NSError)
        XCTAssertTrue(failure.diagnosticSummary.contains("redacted-domain"))
        XCTAssertFalse(failure.isServiceConnectionFailure)
    }

    func testOnlyTheTwoCocoaXPCConnectionCodesAreRecognized() {
        XCTAssertEqual(CocoaError.Code.xpcConnectionInterrupted.rawValue, 4097)
        XCTAssertEqual(CocoaError.Code.xpcConnectionInvalid.rawValue, 4099)
        for code in [4097, 4099] {
            let failure = AppleSpeechPreparationFailure(
                stage: .startingAnalyzer,
                underlyingError: NSError(domain: NSCocoaErrorDomain, code: code)
            )
            XCTAssertTrue(failure.isServiceConnectionFailure)
            XCTAssertTrue(failure.localizedDescription.contains("NSCocoaErrorDomain \(code)"))
        }
        for error in [
            NSError(domain: NSCocoaErrorDomain, code: 4101),
            NSError(domain: NSCocoaErrorDomain, code: 4),
            NSError(domain: NSURLErrorDomain, code: 4099),
            NSError(domain: "SFSpeechErrorDomain", code: 4097),
            NSError(domain: "NSCocoaErrorDomain/private", code: 4099)
        ] {
            XCTAssertFalse(AppleSpeechPreparationFailure(
                stage: .loadingAssets, underlyingError: error
            ).isServiceConnectionFailure)
        }
    }

    func testAllPreparationStagesHaveDistinctChineseDiagnostics() {
        let stages: [(AppleSpeechPreparationStage, String)] = [
            (.checkingAssets, "检查识别资产"),
            (.checkingInstalledLocales, "检查已安装语种"),
            (.preparingExistingAssets, "加载已有识别资产"),
            (.requestingInstallation, "请求安装识别资产"),
            (.installingAssets, "下载并安装识别资产"),
            (.checkingAssetsAfterInstallation, "检查安装后的识别资产"),
            (.checkingAssetsAfterPreparation, "检查加载后的识别资产"),
            (.loadingAssets, "加载识别资产"),
            (.choosingAudioFormat, "选择音频格式"),
            (.preparingAudioFormat, "准备音频格式"),
            (.startingAnalyzer, "启动语音分析")
        ]
        var descriptions = Set<String>()
        for (stage, label) in stages {
            let failure = AppleSpeechPreparationFailure(
                stage: stage, underlyingError: NSError(domain: NSPOSIXErrorDomain, code: 5)
            )
            XCTAssertEqual(failure.stage, stage)
            XCTAssertTrue(failure.localizedDescription.contains("阶段：\(label)"))
            XCTAssertTrue(failure.diagnosticSummary.contains(stage.rawValue))
            XCTAssertTrue(failure.diagnosticSummary.contains("NSPOSIXErrorDomain 5"))
            XCTAssertTrue(failure.localizedDescription.contains("录音仍保存在本机"))
            descriptions.insert(failure.localizedDescription)
        }
        XCTAssertEqual(descriptions.count, stages.count)
    }

    func testDescriptionsDoNotEchoDomainsMessagesPathsURLsOrArbitraryUserInfo() {
        let sensitiveValues = [
            "/Users/synthetic/private/meeting.caf", "ABSK_SYNTHETIC_DOMAIN",
            "https://private.example.invalid/asset", "synthetic-authorization",
            "private-asset-identifier"
        ]
        let inner = NSError(
            domain: NSCocoaErrorDomain, code: 4099,
            userInfo: [NSLocalizedDescriptionKey: sensitiveValues.joined(separator: " "),
                       NSFilePathErrorKey: sensitiveValues[0], "authorization": sensitiveValues[3]]
        )
        let original = NSError(
            domain: "com.apple.private.\(sensitiveValues.joined(separator: "."))", code: 123,
            userInfo: [NSUnderlyingErrorKey: inner, "private_asset": sensitiveValues[4]]
        )
        let failure = AppleSpeechPreparationFailure(
            stage: .requestingInstallation, underlyingError: original
        )
        let displayed = failure.diagnosticSummary + failure.localizedDescription
            + String(describing: failure) + String(reflecting: failure)
            + (failure as NSError).localizedDescription
        for value in sensitiveValues { XCTAssertFalse(displayed.contains(value)) }
        XCTAssertTrue(failure.diagnosticSummary.contains("redacted-domain 123"))
        XCTAssertTrue(failure.diagnosticSummary.contains("NSCocoaErrorDomain 4099"))
        XCTAssertTrue((failure.underlyingError as NSError) === original)
        XCTAssertEqual((failure.underlyingError as NSError).userInfo["private_asset"] as? String,
                       sensitiveValues[4])
    }

    func testUnknownErrorsDoNotInventNetworkDiskOrPermissionExplanations() {
        let failure = AppleSpeechPreparationFailure(
            stage: .installingAssets,
            underlyingError: NSError(domain: "unknown.private.domain", code: 99)
        )
        XCTAssertFalse(failure.isServiceConnectionFailure)
        for explanation in ["网络", "磁盘", "权限", "空间不足", "服务连接失败"] {
            XCTAssertFalse(failure.localizedDescription.contains(explanation))
        }
        XCTAssertTrue(failure.localizedDescription.contains("下载并安装识别资产"))
    }

    func testDeepErrorChainHasABoundedDiagnosticAndPreservesTheFullOriginal() {
        var original = NSError(domain: NSCocoaErrorDomain, code: 4099)
        for code in 0..<32 {
            original = NSError(
                domain: NSPOSIXErrorDomain, code: code, userInfo: [NSUnderlyingErrorKey: original]
            )
        }
        let failure = AppleSpeechPreparationFailure(
            stage: .loadingAssets, underlyingError: original
        )
        XCTAssertTrue(failure.diagnosticSummary.contains("诊断链已截断"))
        XCTAssertLessThanOrEqual(failure.diagnosticSummary.components(separatedBy: " → ").count, 8)
        XCTAssertFalse(failure.isServiceConnectionFailure)
        XCTAssertTrue((failure.underlyingError as NSError) === original)
        var originalDepth = 1
        var cursor = original
        while let next = cursor.userInfo[NSUnderlyingErrorKey] as? NSError {
            originalDepth += 1
            cursor = next
        }
        XCTAssertEqual(originalDepth, 33)
        XCTAssertEqual(cursor.code, 4099)
    }

    func testRepeatedAndCyclicErrorReferencesCannotLoopDiagnostics() {
        let cyclic = MutableUnderlyingNSError(domain: NSPOSIXErrorDomain, code: 5)
        cyclic.underlying = cyclic
        defer { cyclic.underlying = nil }
        let failure = AppleSpeechPreparationFailure(
            stage: .choosingAudioFormat, underlyingError: cyclic
        )
        XCTAssertTrue(failure.diagnosticSummary.contains("重复错误节点已省略"))
        XCTAssertEqual(failure.diagnosticSummary.components(separatedBy: "NSPOSIXErrorDomain 5").count, 2)
        XCTAssertFalse(failure.isServiceConnectionFailure)
    }

    func testMultipleUnderlyingErrorsAreBoundedAndRecognizeAnXPCChild() {
        let xpc = NSError(domain: NSCocoaErrorDomain, code: 4097)
        let children = [xpc] + (0..<40).map { NSError(domain: NSPOSIXErrorDomain, code: $0) }
        let original = NSError(domain: "SFSpeechErrorDomain", code: 9, userInfo: [
            multipleUnderlyingErrorsKey: children
        ])
        let failure = AppleSpeechPreparationFailure(
            stage: .preparingAudioFormat, underlyingError: original
        )
        XCTAssertTrue(failure.isServiceConnectionFailure)
        XCTAssertTrue(failure.diagnosticSummary.contains("诊断链已截断"))
        XCTAssertLessThanOrEqual(failure.diagnosticSummary.components(separatedBy: " → ").count, 12)
        XCTAssertTrue((failure.underlyingError as NSError) === original)
    }

    func testWrappingHelperPreservesCancellationInsteadOfPresentingItAsFailure() {
        let cancellation = CancellationError()
        let result = AppleSpeechPreparationFailure.wrapping(
            stage: .loadingAssets, underlyingError: cancellation
        )
        XCTAssertTrue(result is CancellationError)
        XCTAssertFalse(result is AppleSpeechPreparationFailure)
        let original = NSError(domain: NSCocoaErrorDomain, code: 4099)
        let wrapped = AppleSpeechPreparationFailure.wrapping(
            stage: .loadingAssets, underlyingError: original
        )
        XCTAssertTrue(wrapped is AppleSpeechPreparationFailure)
        XCTAssertTrue(((wrapped as? AppleSpeechPreparationFailure)?.underlyingError as? NSError) === original)
    }
}

private final class MutableUnderlyingNSError: NSError {
    var underlying: NSError?
    override var userInfo: [String: Any] {
        underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
    }
    init(domain: String, code: Int) { super.init(domain: domain, code: code, userInfo: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used by these tests") }
}

#if os(macOS)
private let multipleUnderlyingErrorsKey = NSMultipleUnderlyingErrorsKey
#else
private let multipleUnderlyingErrorsKey = "NSMultipleUnderlyingErrors"
#endif
