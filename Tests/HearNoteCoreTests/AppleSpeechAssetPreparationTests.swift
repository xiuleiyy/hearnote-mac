import Foundation
import XCTest
@testable import HearNoteCore

final class AppleSpeechAssetPreparationTests: XCTestCase {
    @MainActor
    func testSupportedAssetsWithInstalledLocalePrepareWithoutInstallation() async throws {
        let system = AssetSystem(statuses: [.supported], localeInstalled: true)
        system.installationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        try await system.run()

        XCTAssertTrue(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .installedLocales, .prepare, .postPreparationStatus])
        XCTAssertTrue(system.events.contains { $0.stage == .preparingExistingAssets })
        XCTAssertEqual(system.events.last?.stage, .checkingAssetsAfterPreparation)
        XCTAssertEqual(system.events.last?.initialStatus, .supported)
        XCTAssertEqual(system.events.last?.hasInstalledLocale, true)
        XCTAssertTrue(system.events.allSatisfy { $0.installationRequested == nil })
    }

    @MainActor
    func testInstalledAssetsPrepareWithoutQueryingLocalesOrInstalling() async throws {
        let system = AssetSystem(statuses: [.installed])

        try await system.run()

        XCTAssertTrue(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .prepare, .postPreparationStatus])
        XCTAssertEqual(system.events.last?.stage, .checkingAssetsAfterPreparation)
        XCTAssertEqual(system.events.last?.hasInstalledLocale, nil)
    }

    @MainActor
    func testInstalledAssetsLoadFailureKeepsOriginalErrorWithoutReinstalling() async {
        let original = NSError(domain: NSCocoaErrorDomain, code: 4099, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "SpeechAssetTest", code: 7)
        ])
        let system = AssetSystem(statuses: [.installed])
        system.preparationError = original

        do {
            try await system.run()
            XCTFail("A failed load cannot become ready.")
        } catch {
            XCTAssertTrue((error as NSError) === original)
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, 4099)
            XCTAssertEqual(((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code, 7)
        }

        XCTAssertFalse(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .prepare])
    }

    @MainActor
    func testNilInstallationRequestAndSupportedStatusCanStillPrepare() async throws {
        let system = AssetSystem(statuses: [.supported, .supported], installationRequested: false)

        try await system.run()

        XCTAssertTrue(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .installedLocales, .install, .postStatus, .prepare])
        XCTAssertEqual(system.events.last?.stage, .loadingAssets)
        XCTAssertEqual(system.events.last?.initialStatus, .supported)
        XCTAssertEqual(system.events.last?.observedStatus, .supported)
        XCTAssertEqual(system.events.last?.installationRequested, false)
    }

    @MainActor
    func testInstallationRequestCanPrepareWhilePostStatusStillSupported() async throws {
        let system = AssetSystem(statuses: [.downloading, .supported], installationRequested: true)

        try await system.run()

        XCTAssertTrue(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .installedLocales, .install, .postStatus, .prepare])
        XCTAssertEqual(system.events.last?.initialStatus, .downloading)
        XCTAssertEqual(system.events.last?.observedStatus, .supported)
        XCTAssertEqual(system.events.last?.installationRequested, true)
    }

    @MainActor
    func testInstalledPostStatusDoesNotSkipActualLoading() async throws {
        let system = AssetSystem(statuses: [.supported, .installed], installationRequested: true)

        try await system.run()

        XCTAssertTrue(system.ready)
        XCTAssertEqual(system.calls.last, .prepare)
        XCTAssertEqual(system.events.last?.observedStatus, .installed)
    }

    @MainActor
    func testMissingAssetsPropagateOriginalLoadErrorAndUnderlyingChain() async {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 4099)
        let original = NSError(domain: "SpeechAssetTest", code: 27,
                               userInfo: [NSUnderlyingErrorKey: underlying])
        let system = AssetSystem(statuses: [.supported, .supported], installationRequested: false)
        system.preparationError = original

        do {
            try await system.run()
            XCTFail("A nil installation request does not prove assets are usable.")
        } catch {
            XCTAssertTrue((error as NSError) === original)
            XCTAssertTrue(((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError) === underlying)
        }

        XCTAssertFalse(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .installedLocales, .install, .postStatus, .prepare])
        XCTAssertEqual(system.events.last?.installationRequested, false)
    }

    @MainActor
    func testInstallationFailureIsNotReplacedByStatusOrLoadingErrors() async {
        let original = NSError(domain: NSCocoaErrorDomain, code: 4099)
        let system = AssetSystem(statuses: [.supported], installationRequested: true)
        system.installationError = original

        do {
            try await system.run()
            XCTFail("Installation failure must reach the caller.")
        } catch {
            XCTAssertTrue((error as NSError) === original)
        }

        XCTAssertFalse(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus, .installedLocales, .install])
        XCTAssertEqual(system.events.last?.stage, .requestingInstallation)
    }

    @MainActor
    func testUnsupportedStatusStopsBeforeLocaleQueryOrInstallation() async {
        let system = AssetSystem(statuses: [.unsupported])

        do {
            try await system.run()
            XCTFail("Unsupported assets cannot be prepared.")
        } catch {
            XCTAssertEqual(error as? AppleSpeechAssetPreparationError, .unsupportedAssets)
        }

        XCTAssertFalse(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus])
    }

    @MainActor
    func testCancellationBeforeFirstAwaitDoesNotTouchSystemOrEmitEvents() async {
        let system = AssetSystem(statuses: [.supported])
        let caller = Task { @MainActor in try await system.run() }
        caller.cancel()

        do {
            try await caller.value
            XCTFail("An already cancelled caller must not prepare assets.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(system.calls.isEmpty)
        XCTAssertTrue(system.events.isEmpty)
        XCTAssertFalse(system.ready)
    }

    @MainActor
    func testCancellationAfterEveryAwaitPreventsLaterWorkAndReady() async {
        let scenarios: [(AssetSystem.Call, [AppleSpeechAssetStatus], [AssetSystem.Call])] = [
            (.initialStatus, [.supported], [.initialStatus]),
            (.installedLocales, [.supported], [.initialStatus, .installedLocales]),
            (.install, [.supported], [.initialStatus, .installedLocales, .install]),
            (.postStatus, [.supported, .supported], [.initialStatus, .installedLocales, .install, .postStatus]),
            (.prepare, [.supported, .supported], [.initialStatus, .installedLocales, .install, .postStatus, .prepare]),
            (.prepare, [.installed], [.initialStatus, .prepare]),
            (.postPreparationStatus, [.installed, .supported], [.initialStatus, .prepare, .postPreparationStatus])
        ]
        for (pause, statuses, expectedCalls) in scenarios {
            let entered = expectation(description: "entered \(pause), initial \(statuses[0])")
            let system = AssetSystem(statuses: statuses, installationRequested: true)
            system.pauseAt = pause
            system.entered = entered
            let caller = Task { @MainActor in try await system.run() }
            await fulfillment(of: [entered], timeout: 2)
            let eventCountAtCancellation = system.events.count

            caller.cancel()
            system.release()
            do {
                try await caller.value
                XCTFail("Cancelled \(pause) must not report readiness.")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }

            XCTAssertEqual(system.calls, expectedCalls)
            XCTAssertEqual(system.events.count, eventCountAtCancellation)
            XCTAssertFalse(system.ready)
        }
    }

    @MainActor
    func testRunGenerationInvalidationAfterAwaitPreventsLatePreparation() async {
        let entered = expectation(description: "initial status in progress")
        let system = AssetSystem(statuses: [.supported], localeInstalled: true)
        system.pauseAt = .initialStatus
        system.entered = entered
        let caller = Task { @MainActor in try await system.run() }
        await fulfillment(of: [entered], timeout: 2)
        system.isCurrentRun = false
        system.release()

        do {
            try await caller.value
            XCTFail("A replaced run must not continue loading assets.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertFalse(system.ready)
        XCTAssertEqual(system.calls, [.initialStatus])
    }

    @MainActor
    func testCancellingOneSourceDoesNotCancelSharedInstallationForOtherSource() async throws {
        let microphoneEntered = expectation(description: "microphone awaiting installation")
        let systemEntered = expectation(description: "system awaiting installation")
        let microphoneCancelled = expectation(description: "microphone caller settles promptly")
        let microphoneFlowEnded = expectation(description: "late microphone flow rejects success")
        let microphone = AssetSystem(statuses: [.supported, .supported], installationRequested: true)
        let system = AssetSystem(statuses: [.supported, .supported], installationRequested: true)
        microphone.pauseAt = .install
        microphone.entered = microphoneEntered
        system.pauseAt = .install
        system.entered = systemEntered
        var microphoneCancelCount = 0
        var systemCancelCount = 0
        let microphoneOperation = AppleSpeechStartOperation { microphoneCancelCount += 1 }
        let systemOperation = AppleSpeechStartOperation { systemCancelCount += 1 }
        let microphoneCaller = Task { @MainActor in
            do {
                try await microphoneOperation.run {
                    defer { microphoneFlowEnded.fulfill() }
                    try await microphone.run()
                }
                XCTFail("Cancelled microphone must not become ready.")
            } catch is CancellationError {
                microphoneCancelled.fulfill()
            } catch {
                XCTFail("Unexpected microphone error: \(error)")
            }
        }
        let systemCaller = Task { @MainActor in
            try await systemOperation.run { try await system.run() }
        }
        await fulfillment(of: [microphoneEntered, systemEntered], timeout: 2)
        microphoneCaller.cancel()
        await fulfillment(of: [microphoneCancelled], timeout: 1)
        XCTAssertEqual(microphoneCancelCount, 1)
        XCTAssertEqual(systemCancelCount, 0)

        // 系统安装独立于本 App 的等待者；相同下载晚到，两来源分别处理自己的取消。
        microphone.release()
        system.release()
        await microphoneCaller.value
        try await systemCaller.value
        await fulfillment(of: [microphoneFlowEnded], timeout: 2)

        XCTAssertFalse(microphone.ready)
        XCTAssertTrue(system.ready)
        XCTAssertEqual(microphone.calls, [.initialStatus, .installedLocales, .install])
        XCTAssertEqual(system.calls, [.initialStatus, .installedLocales, .install, .postStatus, .prepare])
        systemOperation.cancel()
        XCTAssertEqual(systemCancelCount, 0)
    }

    func testInstalledLocaleMatchingNormalizesSeparatorsButPreservesRegionAndScript() {
        let locales = [Locale(identifier: "en_US"), Locale(identifier: "zh_CN")]
        XCTAssertTrue(AppleSpeechAssetPreparation.matchesInstalledLocale(
            requested: Locale(identifier: "en-US"), installed: locales))
        XCTAssertTrue(AppleSpeechAssetPreparation.matchesInstalledLocale(
            requested: Locale(identifier: "zh-CN"), installed: locales))
        XCTAssertFalse(AppleSpeechAssetPreparation.matchesInstalledLocale(
            requested: Locale(identifier: "zh-TW"), installed: locales))
        XCTAssertFalse(AppleSpeechAssetPreparation.matchesInstalledLocale(
            requested: Locale(identifier: "en-GB"), installed: locales))
        XCTAssertFalse(AppleSpeechAssetPreparation.matchesInstalledLocale(
            requested: Locale(identifier: "zh-Hant-CN"), installed: locales))
        XCTAssertFalse(AppleSpeechAssetPreparation.matchesInstalledLocale(
            requested: Locale(identifier: "en-US"), installed: []))
    }
}

@MainActor
private final class AssetSystem {
    enum Call: String {
        case initialStatus, installedLocales, install, postStatus, prepare, postPreparationStatus
    }

    let statuses: [AppleSpeechAssetStatus]
    let localeInstalled: Bool
    let installationRequested: Bool
    var installationError: NSError?
    var preparationError: NSError?
    var pauseAt: Call?
    var entered: XCTestExpectation?
    var isCurrentRun = true
    private(set) var calls: [Call] = []
    private(set) var events: [AppleSpeechAssetPreparation.Event] = []
    private(set) var ready = false
    private var statusCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(statuses: [AppleSpeechAssetStatus], localeInstalled: Bool = false,
         installationRequested: Bool = false) {
        self.statuses = statuses
        self.localeInstalled = localeInstalled
        self.installationRequested = installationRequested
    }

    func run() async throws {
        try await AppleSpeechAssetPreparation.prepare(
            status: {
                let index = self.statusCount
                self.statusCount += 1
                let call: Call = index == 0 ? .initialStatus :
                    (self.calls.contains(.prepare) ? .postPreparationStatus : .postStatus)
                await self.record(call)
                return self.statuses[min(index, self.statuses.count - 1)]
            },
            hasInstalledLocale: {
                await self.record(.installedLocales)
                return self.localeInstalled
            },
            install: {
                await self.record(.install)
                if let error = self.installationError { throw error }
                return self.installationRequested
            },
            prepare: {
                await self.record(.prepare)
                if let error = self.preparationError { throw error }
            },
            checkCancellation: {
                guard self.isCurrentRun else { throw CancellationError() }
            },
            onEvent: { self.events.append($0) }
        )
        ready = true
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    private func record(_ call: Call) async {
        calls.append(call)
        guard pauseAt == call else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered?.fulfill()
        }
    }
}
