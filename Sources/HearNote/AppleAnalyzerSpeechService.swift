import AVFoundation
import Foundation
import HearNoteCore
import Speech

/// 让旧 SDK 的 LiveSpeechRecognizer 仍可编译；具体新 API 仅在 Swift 6.2+ 中出现。
@MainActor
protocol AppleSpeechStreamingService: AnyObject {
    var backendDescription: String { get }
    func start(
        locale: String, contextualStrings: [String], source: String, origin: Date,
        onUpdate: @escaping (TranscriptSegment, Bool) -> Void,
        onState: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void
    ) async throws
    func append(_ buffer: AVAudioPCMBuffer, at offset: Double?)
    func appendForTranscription(_ buffer: AVAudioPCMBuffer, at offset: Double) async throws
    func stop()
    func finish(timeout: TimeInterval) async
    func cancel()
}

#if compiler(>=6.2)
import CoreMedia

/// SpeechAnalyzer 自行管理本机识别，不请求旧 SFSpeechRecognizer/Siri 的授权。
/// 模型安装仍需网络；录音由调用方独立保存，准备期间不积压整场 PCM。
@available(macOS 26.0, *)
@MainActor
final class AppleAnalyzerSpeechService: AppleSpeechStreamingService {
    private(set) var backendDescription = "Apple SpeechAnalyzer"
    private var runID: UUID?
    private var analyzer: SpeechAnalyzer?
    private var audioFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<QueuedInput>.Continuation?
    private var inputBudget = AppleSpeechInputBudget()
    private var timeline = AppleSpeechInputTimeline()
    private var mapper = AppleSpeechResultMapper()
    private var origin = Date()
    private var source = ""
    private var acceptingAudio = false
    private var receivedAudio = false
    private var currentFailure: Error?
    private var resultTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var update: ((TranscriptSegment, Bool) -> Void)?
    private var state: ((String, Bool) -> Void)?
    private var failure: ((Error) -> Void)?

    func start(
        locale: String, contextualStrings: [String], source: String, origin: Date,
        onUpdate: @escaping (TranscriptSegment, Bool) -> Void,
        onState: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void
    ) async throws {
        cancel()
        let id = UUID()
        runID = id
        self.source = source
        self.origin = origin
        update = onUpdate
        state = onState
        failure = onError
        currentFailure = nil
        mapper = AppleSpeechResultMapper()
        timeline = AppleSpeechInputTimeline()
        inputBudget = AppleSpeechInputBudget()
        setState("正在检查本机语言支持…", ready: false)
        do {
            let module = try await makeModule(locale: Locale(identifier: locale))
            try checkRun(id)
            backendDescription = module.description
            let modules: [any SpeechModule] = [module.module]
            try await ensureAssets(modules: modules, id: id)
            try checkRun(id)
            // Apple 文档要求先安装模块资产，才能查询正确的 compatible audio format。
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw AppleAnalyzerError.audioFormatUnavailable
            }
            try checkRun(id)
            audioFormat = format
            let analyzer = SpeechAnalyzer(modules: modules)
            self.analyzer = analyzer
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
                try await analyzer.setContext(context)
                try checkRun(id)
            }
            setState("正在准备本机识别模型…", ready: false)
            try await analyzer.prepareToAnalyze(in: format)
            try checkRun(id)
            let (stream, continuation) = AsyncStream<QueuedInput>.makeStream()
            inputContinuation = continuation
            switch module {
            case .speech(let transcriber):
                resultTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self, self.runID == id, !Task.isCancelled else { return }
                            self.receive(text: result.text, range: result.range,
                                         isFinal: result.isFinal,
                                         finalizationTime: result.resultsFinalizationTime)
                        }
                        self?.resultsEnded(id: id)
                    } catch {
                        self?.resultsFailed(error, id: id)
                    }
                }
            case .dictation(let transcriber):
                resultTask = Task { [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self, self.runID == id, !Task.isCancelled else { return }
                            self.receive(text: result.text, range: result.range,
                                         isFinal: result.isFinal,
                                         finalizationTime: result.resultsFinalizationTime)
                        }
                        self?.resultsEnded(id: id)
                    } catch {
                        self?.resultsFailed(error, id: id)
                    }
                }
            }
            try await analyzer.start(inputSequence: BudgetedInputSequence(
                stream: stream, budget: inputBudget
            ))
            try checkRun(id)
            acceptingAudio = true
            setState("等待音频", ready: true)
        } catch {
            if runID == id {
                let wasCancelled = error is CancellationError || Task.isCancelled
                cancel()
                onState(wasCancelled ? "已停止" : "\(backendDescription) · 识别未就绪", false)
            }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at offset: Double?) {
        guard let id = runID, acceptingAudio, buffer.frameLength > 0 else { return }
        do {
            let converted = try convert(buffer)
            guard converted.frameLength > 0 else { return }
            guard enqueue(converted, at: offset) else {
                throw AppleAnalyzerError.inputBacklog
            }
        } catch {
            fail(error, id: id)
        }
    }

    /// 文件读取有背压，避免把整个音频文件一次性留在输入序列中。
    func appendForTranscription(_ buffer: AVAudioPCMBuffer, at offset: Double) async throws {
        if let currentFailure { throw currentFailure }
        guard let id = runID, acceptingAudio else { throw CancellationError() }
        let converted = try convert(buffer)
        guard converted.frameLength > 0 else { return }
        let deadline = Date().addingTimeInterval(20)
        while true {
            try checkRun(id)
            if let currentFailure { throw currentFailure }
            guard acceptingAudio else { throw CancellationError() }
            if enqueue(converted, at: offset) { return }
            guard Date() < deadline else {
                let error = AppleAnalyzerError.inputBacklog
                fail(error, id: id)
                throw error
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func stop() {
        beginFinishing(timeout: 20)
    }

    private func beginFinishing(timeout requestedTimeout: TimeInterval) {
        guard let id = runID else { return }
        guard completionTask == nil else { return }
        // 资源准备尚未完成时，不等下载结束才能保存录音。
        guard let analyzer, let continuation = inputContinuation else {
            cancel()
            return
        }
        let timeout = requestedTimeout.isFinite ? min(300, max(1, requestedTimeout)) : 20
        acceptingAudio = false
        continuation.finish()
        inputContinuation = nil
        setState("正在收尾…", ready: false)
        completionTask = Task { [weak self, analyzer] in
            do {
                // 先 finish 输入，才能等待所有已投喂 PCM 和 volatile 结果被 finalize。
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                guard let self, self.runID == id else { return }
                await self.resultTask?.value
                guard self.runID == id else { return }
                for result in self.mapper.finishSuccessfully() {
                    self.update?(result.segment, result.isFinal)
                }
                self.complete(id: id, status: "已停止")
            } catch {
                guard let self, self.runID == id else { return }
                self.fail(error, id: id)
            }
        }
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            catch { return }
            guard let self, self.runID == id else { return }
            self.fail(AppleAnalyzerError.finalResultTimedOut(
                hadAudio: self.receivedAudio, hadPartial: self.mapper.hasPendingText,
                timeout: Int(timeout)
            ), id: id)
        }
    }

    func finish(timeout: TimeInterval = 20) async {
        beginFinishing(timeout: timeout)
        guard let id = runID else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if runID != id { continuation.resume() }
                else { finishWaiters.append(continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.runID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        runID = nil
        acceptingAudio = false
        receivedAudio = false
        progressTask?.cancel()
        progressTask = nil
        resultTask?.cancel()
        resultTask = nil
        completionTask?.cancel()
        completionTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        audioFormat = nil
        converter = nil
        converterInputFormat = nil
        update = nil
        state = nil
        failure = nil
        resumeFinishWaiters()
    }

    private enum Module {
        case speech(Speech.SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let value): return value
            case .dictation(let value): return value
            }
        }

        var description: String {
            switch self {
            case .speech: return "Apple SpeechTranscriber（本机）"
            case .dictation: return "Apple DictationTranscriber（本机）"
            }
        }
    }

    private func makeModule(locale: Locale) async throws -> Module {
        if Speech.SpeechTranscriber.isAvailable,
           let supported = await Speech.SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(Speech.SpeechTranscriber(
                locale: supported, transcriptionOptions: [],
                reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange]
            ))
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(DictationTranscriber(
                locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange]
            ))
        }
        throw AppleAnalyzerError.localeUnsupported(locale.identifier)
    }

    private func ensureAssets(modules: [any SpeechModule], id: UUID) async throws {
        let status = await AssetInventory.status(forModules: modules)
        try checkRun(id)
        guard status != .unsupported else {
            throw AppleAnalyzerError.assetsUnsupported
        }
        if status == .installed { return }
        setState(status == .downloading ? "正在等待本机模型安装…" : "正在请求本机模型资源…",
                 ready: false)
        do {
            // 此调用按需 reserve 语言；不要 stop 时 release，以免两源或其他会话互相卸载。
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try checkRun(id)
                let progress = request.progress
                progressTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.runID == id else { return }
                        let fraction = progress.fractionCompleted
                        if fraction.isFinite, progress.totalUnitCount > 0 {
                            let percentage = Int(min(1, max(0, fraction)) * 100)
                            self.setState("正在下载并安装本机模型 \(percentage)%…", ready: false)
                        } else {
                            self.setState("正在下载并安装本机模型…", ready: false)
                        }
                        do { try await Task.sleep(nanoseconds: 250_000_000) }
                        catch { return }
                    }
                }
                defer {
                    if runID == id {
                        progressTask?.cancel()
                        progressTask = nil
                    }
                }
                try await request.downloadAndInstall()
                try checkRun(id)
            }
            guard await AssetInventory.status(forModules: modules) == .installed else {
                throw AppleAnalyzerError.assetsNotInstalled
            }
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw AppleAnalyzerError.assetInstallationFailed(error.localizedDescription)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let target = audioFormat,
              buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0 else { throw AppleAnalyzerError.invalidAudio }
        if buffer.format == target { return buffer }
        if converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // 使已转换 PCM 与原始 startTime 对齐；不让 priming 把音频移到下一帧。
            converter?.primeMethod = .none
            converterInputFormat = buffer.format
        }
        guard let converter else { throw AppleAnalyzerError.audioConversionFailed }
        let capacity = ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity))
        else { throw AppleAnalyzerError.invalidAudio }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if let conversionError { throw conversionError }
            throw AppleAnalyzerError.audioConversionFailed
        }
        return output
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, at offset: Double?) -> Bool {
        guard let continuation = inputContinuation else { return false }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let bytes = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            .reduce(0) { $0 + Int($1.mDataByteSize) }
        guard let token = inputBudget.reserve(duration: duration, bytes: bytes) else { return false }
        let requested = offset ?? max(0, Date().timeIntervalSince(origin))
        guard let start = timeline.place(duration: duration, requestedStart: requested) else {
            inputBudget.consumed(token)
            return false
        }
        let input = AnalyzerInput(
            buffer: buffer, bufferStartTime: CMTime(seconds: start, preferredTimescale: 1_000_000_000)
        )
        switch continuation.yield(QueuedInput(input: input, token: token)) {
        case .enqueued:
            receivedAudio = true
            setState("识别中", ready: true)
            return true
        case .dropped, .terminated:
            inputBudget.consumed(token)
            return false
        @unknown default:
            inputBudget.consumed(token)
            return false
        }
    }

    private func receive(text: AttributedString, range: CMTimeRange, isFinal: Bool,
                         finalizationTime: CMTime) {
        let start = range.start.seconds
        let end = CMTimeRangeGetEnd(range).seconds
        let fragments = timedFragments(text, fallback: range)
        for result in mapper.receive(
            text: String(text.characters), start: start, end: end, isFinal: isFinal,
            resultsFinalizationTime: finalizationTime.seconds, source: source, timedText: fragments
        ) {
            update?(result.segment, result.isFinal)
        }
    }

    private func timedFragments(_ text: AttributedString, fallback: CMTimeRange)
        -> [AppleSpeechResultMapper.TimedText] {
        var fragments: [AppleSpeechResultMapper.TimedText] = []
        var leading = ""
        for run in text.runs {
            let content = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                let start = range.start.seconds
                let end = CMTimeRangeGetEnd(range).seconds
                if start.isFinite, end.isFinite, end >= start {
                    fragments.append(.init(text: leading + content, start: start, end: end))
                    leading = ""
                    continue
                }
            }
            if let last = fragments.popLast() {
                fragments.append(.init(text: last.text + content, start: last.start, end: last.end))
            } else { leading += content }
        }
        // 未提供有效时间属性时只保留整段；绝不按字符比例猜测局部时间。
        if fragments.isEmpty, !String(text.characters).isEmpty {
            return [.init(text: String(text.characters), start: fallback.start.seconds,
                          end: CMTimeRangeGetEnd(fallback).seconds)]
        }
        return fragments
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id else { throw CancellationError() }
    }

    private func setState(_ detail: String, ready: Bool) {
        state?("\(backendDescription) · \(detail)", ready)
    }

    private func resultsEnded(id: UUID) {
        guard runID == id, acceptingAudio else { return }
        fail(AppleAnalyzerError.resultsEndedEarly, id: id)
    }

    private func resultsFailed(_ error: Error, id: UUID) {
        guard runID == id, !(error is CancellationError), !Task.isCancelled else { return }
        fail(error, id: id)
    }

    private func fail(_ error: Error, id: UUID) {
        guard runID == id else { return }
        currentFailure = error
        let notify = failure
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        complete(id: id, status: "识别失败")
        notify?(error)
    }

    private func complete(id: UUID, status: String) {
        guard runID == id else { return }
        runID = nil
        acceptingAudio = false
        inputContinuation?.finish()
        inputContinuation = nil
        resultTask?.cancel()
        resultTask = nil
        completionTask?.cancel()
        completionTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        progressTask?.cancel()
        progressTask = nil
        analyzer = nil
        converter = nil
        converterInputFormat = nil
        audioFormat = nil
        setState(status, ready: false)
        update = nil
        state = nil
        failure = nil
        resumeFinishWaiters()
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private struct QueuedInput: Sendable {
        let input: AnalyzerInput
        let token: UUID
    }

    private struct BudgetedInputSequence: AsyncSequence, Sendable {
        typealias Element = AnalyzerInput
        let stream: AsyncStream<QueuedInput>
        let budget: AppleSpeechInputBudget

        func makeAsyncIterator() -> Iterator {
            Iterator(base: stream.makeAsyncIterator(), budget: budget)
        }

        struct Iterator: AsyncIteratorProtocol {
            var base: AsyncStream<QueuedInput>.Iterator
            let budget: AppleSpeechInputBudget

            mutating func next() async -> AnalyzerInput? {
                guard let value = await base.next() else { return nil }
                budget.consumed(value.token)
                return value.input
            }
        }
    }
}

@available(macOS 26.0, *)
private enum AppleAnalyzerError: LocalizedError {
    case localeUnsupported(String)
    case assetsUnsupported
    case assetsNotInstalled
    case assetInstallationFailed(String)
    case audioFormatUnavailable
    case invalidAudio
    case audioConversionFailed
    case inputBacklog
    case resultsEndedEarly
    case finalResultTimedOut(hadAudio: Bool, hadPartial: Bool, timeout: Int)

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale):
            return "此 Mac 的 Apple 本机识别不支持 \(locale)。请选择受支持的单一语种后重试；录音仍保留。"
        case .assetsUnsupported:
            return "此 Mac 不支持所选 Apple 本机模型。请选择其他受支持的语种；录音仍保留。"
        case .assetsNotInstalled:
            return "Apple 本机模型尚未安装完成。请检查网络和磁盘空间后重试；录音仍保留。"
        case .assetInstallationFailed(let detail):
            return "Apple 本机模型安装失败：\(detail)。请检查网络、磁盘空间或系统语言资源后重试；录音仍保留。"
        case .audioFormatUnavailable:
            return "Apple 模型已安装，但没有可用的识别音频格式。请重试；录音仍保留。"
        case .invalidAudio:
            return "收到的音频格式或时间无效，Apple 识别无法继续。录音仍保留，可在会后重新转写。"
        case .audioConversionFailed:
            return "音频无法转换为 Apple 模型需要的格式。录音仍保留，可在会后重新转写。"
        case .inputBacklog:
            return "Apple 实时识别处理积压超过上限，已停止转写以避免悄悄丢帧。录音继续保存，可在会后重新转写。"
        case .resultsEndedEarly:
            return "Apple 本机识别提前结束。录音继续保存，可在会后重新转写。"
        case .finalResultTimedOut(let hadAudio, let hadPartial, let timeout):
            return hadPartial
                ? "Apple 识别未在 \(timeout) 秒内返回最终结果，已保留临时文字和录音，可在会后重新转写。"
                : hadAudio
                    ? "Apple 已收到音频，但未在 \(timeout) 秒内完成收尾。音频可能是静音；录音仍保留，可在会后重新转写。"
                    : "Apple 识别未在 \(timeout) 秒内完成收尾，本次未收到识别音频；录音文件由采集线路独立保存。"
        }
    }
}
#endif
