#if os(macOS)
import AVFoundation
import Combine
import CoreML
import CoreMedia
import Foundation
import HearNoteCore
import WhisperKit

enum WhisperSpeechError: LocalizedError {
    case preparationBusy
    case decoderBusy
    case unsupportedModel
    case incompleteLocalModel
    case preparationFailed
    case modelUnavailable
    case audioConversion
    case decodingBacklog
    case finishingTimedOut

    var errorDescription: String? {
        switch self {
        case .preparationBusy: return "多语种模型正在准备，请等待或先取消。"
        case .decoderBusy: return "语音识别仍在处理，请结束当前任务后再切换模型。"
        case .unsupportedModel: return "请选择支持中英文的多语种模型；英文专用模型不能用于中英混合识别。"
        case .incompleteLocalModel: return "本地模型目录不完整。请导入包含 Core ML 模型、tokenizer.json 和 tokenizer_config.json 的完整目录。"
        case .preparationFailed: return "模型准备失败。请检查网络，或导入完整的本地模型目录后重试。"
        case .modelUnavailable: return "请先下载或导入中英混合识别模型。"
        case .audioConversion: return "音频无法转换为识别所需格式；原始录音仍会保留。"
        case .decodingBacklog: return "本地识别速度暂时跟不上会议音频，已暂停该来源的实时转写。录音继续保存，可在会后重新转写或尝试较小模型。"
        case .finishingTimedOut: return "最后一段混合语音识别超时，已有文字与录音保留，可在会后重新转写。"
        }
    }
}

/// 一份模型供麦克风、系统音和文件转写共享；明确串行解码，避免 actor 重入导致并发推理。
@MainActor
final class WhisperSpeechService: ObservableObject {
    nonisolated static let defaultModelVariant = "large-v3-v20240930_turbo"
    @Published private(set) var isPreparing = false
    @Published private(set) var modelStatus = "中英混合模型尚未准备"
    @Published private(set) var preparationProgress: Double?
    @Published private(set) var preparationElapsed: TimeInterval = 0
    @Published private(set) var loadedModelVariant = ""
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var partialSegments: [TranscriptSegment] = []

    private var kit: WhisperKit?
    private var preparationTask: Task<Void, Error>?
    private var preparationID: UUID?
    private var cancelledPreparationID: UUID?
    private var preparationResult: (id: UUID, result: Result<Void, Error>)?
    private var preparationWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var preparingVariant = ""
    private var preparingFolder: URL?
    private var decodeTail: Task<[TranscriptionResult], Error>?
    private var decodeTailID: UUID?
    private var fileTask: Task<[TranscriptSegment], Error>?
    private var fileRunID: UUID?

    func prepare(modelVariant: String = WhisperSpeechService.defaultModelVariant,
                 modelFolder: URL? = nil) async throws {
        guard ["small", Self.defaultModelVariant].contains(modelVariant),
              modelFolder?.lastPathComponent.contains(".en") != true else {
            throw WhisperSpeechError.unsupportedModel
        }
        if preparationTask != nil, let currentID = preparationID {
            guard preparingVariant == modelVariant, preparingFolder == modelFolder else {
                throw WhisperSpeechError.preparationBusy
            }
            guard cancelledPreparationID != currentID else {
                throw WhisperSpeechError.preparationBusy
            }
            return try await awaitPreparation(id: currentID)
        }
        if kit != nil, loadedModelVariant == modelVariant, modelFolder == nil { return }
        guard decodeTail == nil, !isTranscribing else { throw WhisperSpeechError.decoderBusy }
        if let folder = modelFolder {
            let required = ["tokenizer.json", "tokenizer_config.json"]
            guard Self.hasCoreMLModels(at: folder), required.allSatisfy({
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) else { throw WhisperSpeechError.incompleteLocalModel }
        }
        let id = UUID()
        preparationID = id
        cancelledPreparationID = nil
        preparationResult = nil
        preparingVariant = modelVariant
        preparingFolder = modelFolder
        isPreparing = true
        preparationProgress = nil
        preparationElapsed = 0
        modelStatus = "正在检查本地模型"
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            let startedAt = Date()
            let elapsedTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { return }
                    guard let self, self.preparationID == id,
                          self.cancelledPreparationID != id else { return }
                    self.preparationElapsed = max(0, Date().timeIntervalSince(startedAt))
                }
            }
            var outcome: Result<Void, Error> = .failure(CancellationError())
            var phase = "模型准备"
            defer {
                elapsedTask.cancel()
                if self.preparationID == id {
                    self.preparationProgress = nil
                    self.preparationElapsed = max(0, Date().timeIntervalSince(startedAt))
                    self.preparationResult = (id, outcome)
                    self.resolvePreparationWaiters(outcome)
                    self.preparationID = nil
                    self.preparationTask = nil
                    self.preparingFolder = nil
                    self.cancelledPreparationID = nil
                    self.isPreparing = false
                }
            }
            do {
                try self.checkPreparation(id)
                let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first!
                let cache = support.appendingPathComponent("HearNote/WhisperModels", isDirectory: true)
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let folderKey = "HearNote.whisper.folder.\(modelVariant)"
                let savedPath = UserDefaults.standard.string(forKey: folderKey)
                let cachedFolder = savedPath.flatMap { path -> URL? in
                    let candidate = URL(fileURLWithPath: path, isDirectory: true)
                    return Self.hasCoreMLModels(at: candidate) ? candidate : nil
                }
                // 切换时先释放旧模型，降低两个完整模型同时占用内存的峰值。
                self.kit = nil
                self.loadedModelVariant = ""
                let folder: URL
                if let localFolder = modelFolder ?? cachedFolder {
                    folder = localFolder
                } else {
                    phase = "模型下载"
                    self.modelStatus = "正在下载 \(modelVariant) · 文件准备进度"
                    self.preparationProgress = 0
                    folder = try await WhisperKit.download(
                        variant: modelVariant, downloadBase: cache,
                        progressCallback: { [weak self] progress in
                            // SDK 的总量是文件数；这里只显示真实 fraction，不换算为字节。
                            let fraction = progress.fractionCompleted
                            Task { @MainActor [weak self] in
                                guard let self, self.preparationID == id,
                                      self.cancelledPreparationID != id,
                                      self.preparationProgress != nil,
                                      fraction.isFinite else { return }
                                self.preparationProgress = min(1, max(0, fraction))
                            }
                        }
                    )
                    try self.checkPreparation(id)
                    // tokenizer 或 Core ML 准备失败时仍复用已下载的模型目录。
                    UserDefaults.standard.set(folder.path, forKey: folderKey)
                    self.preparationProgress = nil
                }
                try self.checkPreparation(id)
                phase = "本地模型初始化"
                self.modelStatus = "正在准备本地 \(modelVariant)"
                #if arch(arm64)
                let computeOptions: ModelComputeOptions? = nil
                #else
                // Intel 没有 Apple Neural Engine，使用 CPU/GPU 后端；速度仍需本机测量。
                let computeOptions: ModelComputeOptions? = ModelComputeOptions(
                    melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                )
                #endif
                let prepared = try await WhisperKit(WhisperKitConfig(
                    model: modelVariant, downloadBase: cache, modelFolder: folder.path,
                    computeOptions: computeOptions,
                    verbose: false, prewarm: false, load: false, download: false
                ))
                try self.checkPreparation(id)
                phase = "模型预热"
                self.modelStatus = "正在预热 \(modelVariant) · 首次使用可能较久"
                try await prepared.prewarmModels()
                try self.checkPreparation(id)
                phase = "模型及 tokenizer 加载"
                self.modelStatus = "正在加载模型及 tokenizer · 首次可能需要下载 tokenizer"
                try await prepared.loadModels()
                try self.checkPreparation(id)
                guard prepared.modelVariant.isMultilingual else { throw WhisperSpeechError.unsupportedModel }
                self.kit = prepared
                self.loadedModelVariant = modelVariant
                if let path = prepared.modelFolder?.path {
                    UserDefaults.standard.set(path, forKey: folderKey)
                }
                self.modelStatus = "中英混合模型已准备 · \(modelVariant)"
                outcome = .success(())
            } catch is CancellationError {
                outcome = .failure(CancellationError())
                if self.preparationID == id { self.modelStatus = "模型准备已取消" }
                throw CancellationError()
            } catch {
                // SDK 取消有时以网络错误返回，仍按取消处理，避免错误状态覆盖用户操作。
                if Task.isCancelled || self.cancelledPreparationID == id || self.preparationID != id {
                    outcome = .failure(CancellationError())
                    if self.preparationID == id { self.modelStatus = "模型准备已取消" }
                    throw CancellationError()
                }
                // 下载异常可能包含请求 URL；交给 UI 的错误只保留安全的通用说明。
                let failure = (error as? WhisperSpeechError) ?? .preparationFailed
                outcome = .failure(failure)
                if self.preparationID == id {
                    self.modelStatus = "\(phase)失败，可检查网络或导入完整本地模型目录"
                }
                throw failure
            }
        }
        preparationTask = task
        try await awaitPreparation(id: id)
    }

    private func checkPreparation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard preparationID == id, cancelledPreparationID != id else { throw CancellationError() }
    }

    private static func hasCoreMLModels(at folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                var isDirectory: ObjCBool = false
                let path = folder.appendingPathComponent("\(name).\(ext)", isDirectory: true).path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
        }
    }

    /// SDK 下载/预热未必及时响应 Task.cancel；调用方等待独立 continuation，
    /// 取消时主动恢复，后台任务仍隔离到实际退出，不能回写模型或并发准备。
    private func awaitPreparation(id: UUID) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                registerPreparationWaiter(continuation, id: id, waiterID: waiterID)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.preparationID == id else { return }
                self?.cancelPreparation()
            }
        }
    }

    private func registerPreparationWaiter(_ continuation: CheckedContinuation<Void, Error>,
                                           id: UUID, waiterID: UUID) {
        if let completed = preparationResult, completed.id == id {
            continuation.resume(with: completed.result)
        } else if preparationID == id, cancelledPreparationID != id {
            preparationWaiters[waiterID] = continuation
        } else {
            continuation.resume(throwing: CancellationError())
        }
    }

    private func resolvePreparationWaiters(_ result: Result<Void, Error>) {
        let waiters = preparationWaiters
        preparationWaiters.removeAll()
        for continuation in waiters.values { continuation.resume(with: result) }
    }

    func cancelPreparation() {
        guard let preparationTask, let id = preparationID else { return }
        cancelledPreparationID = id
        preparationTask.cancel()
        let cancellation: Result<Void, Error> = .failure(CancellationError())
        preparationResult = (id, cancellation)
        resolvePreparationWaiters(cancellation)
        preparationProgress = nil
        modelStatus = "正在取消模型准备…"
    }

    func useLocalModelDirectory(_ url: URL,
                               modelVariant: String = WhisperSpeechService.defaultModelVariant) async throws {
        try await prepare(modelVariant: modelVariant, modelFolder: url)
    }

    func makeLiveRecognizer() -> WhisperLiveRecognizer {
        WhisperLiveRecognizer(service: self)
    }

    /// 每次只读取至多 30 秒 PCM，视频与音频统一从音轨提取。
    func transcribe(url: URL, contextualStrings: [String],
                    modelVariant: String = WhisperSpeechService.defaultModelVariant,
                    locale: String = "zh-en") async throws
        -> [TranscriptSegment] {
        let restrictToChineseEnglish = Self.isChineseEnglishLocale(locale)
        guard fileTask == nil else { throw WhisperSpeechError.decoderBusy }
        try await prepare(modelVariant: modelVariant)
        try Task.checkCancellation()
        guard fileTask == nil else { throw WhisperSpeechError.decoderBusy }
        let id = UUID()
        fileRunID = id
        isTranscribing = true
        progress = 0
        partialSegments = []
        let task = Task { @MainActor [weak self] () throws -> [TranscriptSegment] in
            guard let self else { throw CancellationError() }
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw MediaServiceError.noAudio }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw MediaServiceError.invalidDuration }
            var start: Double = 0
            var sentences = TranscriptSentenceAssembler()
            var reconciliation = WhisperWindowReconciliationPolicy()
            var languageSelection = WhisperLanguageSelectionPolicy(locale: locale)
            while start < duration {
                try self.checkFileRun(id)
                let end = min(duration, start + 24)
                let audioStart = max(0, start - 3)
                let audioEnd = min(duration, end + 3)
                let samples = try Self.readAudio(asset: asset, track: track,
                                                start: audioStart, end: audioEnd)
                var results = try await self.decode(
                    samples: samples, contextualStrings: contextualStrings,
                    language: languageSelection.language(coreStart: start, audioEnd: audioEnd),
                    restrictToChineseEnglish: restrictToChineseEnglish
                )
                try self.checkFileRun(id)
                languageSelection.observe(language: results.first?.language, coreStart: start,
                                          audioEnd: audioEnd)
                var snapshot = reconciliation.reconcile(
                    words: Self.absoluteWords(from: results, offset: audioStart),
                    coreStart: start, publicationEnd: end, audioEnd: audioEnd
                )
                if snapshot.requiresConfirmation {
                    // 每个文件窗口最多一次额外确认，不因明显回退无限重跑。
                    results = try await self.decode(
                        samples: samples, contextualStrings: contextualStrings,
                        language: languageSelection.language(coreStart: start, audioEnd: audioEnd),
                        restrictToChineseEnglish: restrictToChineseEnglish
                    )
                    try self.checkFileRun(id)
                    snapshot = reconciliation.reconcile(
                        words: Self.absoluteWords(from: results, offset: audioStart),
                        coreStart: start, publicationEnd: end, audioEnd: audioEnd, confirmed: true
                    )
                }
                let updates = sentences.update(
                    words: snapshot.words, replacingFrom: start, observedThrough: audioEnd,
                    stableThrough: end,
                    followingWord: snapshot.followingWord,
                    finishing: end >= duration
                )
                for update in updates {
                    if update.segment.text.isEmpty {
                        self.partialSegments.removeAll { $0.id == update.segment.id }
                    } else if let index = self.partialSegments.firstIndex(where: { $0.id == update.segment.id }) {
                        self.partialSegments[index] = update.segment
                    } else {
                        self.partialSegments.append(update.segment)
                    }
                }
                self.partialSegments.sort { $0.start < $1.start }
                start = end
                self.progress = start / duration
            }
            return self.partialSegments
        }
        fileTask = task
        defer {
            if fileRunID == id {
                fileRunID = nil
                fileTask = nil
                isTranscribing = false
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
            try Task.checkCancellation()
            return partialSegments
        } onCancel: {
            task.cancel()
        }
    }

    func cancelTranscription() {
        fileRunID = nil
        fileTask?.cancel()
        fileTask = nil
        isTranscribing = false
    }

    private func checkFileRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard fileRunID == id else { throw CancellationError() }
    }

    fileprivate static func isChineseEnglishLocale(_ locale: String) -> Bool {
        locale.lowercased().replacingOccurrences(of: "_", with: "-") == "zh-en"
    }

    fileprivate func decode(samples: [Float], contextualStrings: [String],
                            language: String?, restrictToChineseEnglish: Bool) async throws
        -> [TranscriptionResult] {
        try Task.checkCancellation()
        guard let kit else { throw WhisperSpeechError.modelUnavailable }
        guard Self.hasAudio(samples) else { return [] }
        let predecessor = decodeTail
        let id = UUID()
        let task = Task { @MainActor () throws -> [TranscriptionResult] in
            if let predecessor { _ = try? await predecessor.value }
            try Task.checkCancellation()
            let originalDecoder = kit.textDecoder
            defer { kit.textDecoder = originalDecoder }
            if restrictToChineseEnglish {
                guard let standard = originalDecoder as? TextDecoder,
                      standard.isModelMultilingual, let model = standard.model,
                      let tokenizer = kit.tokenizer else {
                    throw WhisperSpeechError.unsupportedModel
                }
                let scoped = TextDecoder()
                // 共享已加载的模型，不重新加载或复制模型；每个窗口的检测缓存互相独立。
                scoped.model = model
                scoped.isModelMultilingual = standard.isModelMultilingual
                scoped.logitsFilters = standard.logitsFilters
                scoped.tokenizer = try ChineseEnglishTokenizer(base: tokenizer)
                // decodeTail 串行保护 SDK；无论成功、失败还是取消都会恢复默认解码器。
                kit.textDecoder = StableChineseEnglishDecoder(base: scoped)
            }
            var options = DecodingOptions(
                verbose: false, task: .transcribe, language: language,
                temperature: 0, temperatureFallbackCount: 1,
                usePrefillPrompt: true, detectLanguage: language == nil,
                skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: true,
                windowClipTime: 0,
                concurrentWorkerCount: 1
            )
            if let tokenizer = kit.tokenizer, !contextualStrings.isEmpty {
                let prompt = contextualStrings.prefix(40).joined(separator: "，")
                options.promptTokens = Array(
                    tokenizer.encode(text: " " + prompt)
                        .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                        .prefix(96)
                )
            }
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            try Task.checkCancellation()
            return results
        }
        decodeTail = task
        decodeTailID = id
        defer {
            if decodeTailID == id { decodeTail = nil; decodeTailID = nil }
        }
        return try await withTaskCancellationHandler {
            let results = try await task.value
            try Task.checkCancellation()
            return results
        } onCancel: {
            task.cancel()
        }
    }

    fileprivate typealias TimedWord = WhisperTranscriptCleaner.TimedWord

    fileprivate static func absoluteWords(from results: [TranscriptionResult], offset: Double)
        -> [TimedWord] {
        words(from: results).map {
            TimedWord(start: offset + $0.start, end: offset + $0.end, text: $0.text)
        }
    }

    fileprivate static func words(from results: [TranscriptionResult]) -> [TimedWord] {
        let words = results.flatMap(\.segments).flatMap { segment -> [TimedWord] in
            // Whisper 的无语音判定和低置信度结果同时成立时，避免静音幻觉。
            guard !(segment.noSpeechProb >= 0.6 && segment.avgLogprob < -1) else { return [] }
            if let words = segment.words, !words.isEmpty {
                return words.compactMap { word in
                    let start = Double(word.start), end = Double(word.end)
                    guard start.isFinite, end.isFinite, end >= start,
                          !word.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return TimedWord(start: max(0, start), end: max(start, end), text: word.word)
                }
            }
            let start = Double(segment.start), end = Double(segment.end)
            guard start.isFinite, end.isFinite, end >= start,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            return [TimedWord(start: max(0, start), end: end, text: segment.text)]
        }
        return WhisperTranscriptCleaner.removingBlankAudio(from: words).sorted { $0.start < $1.start }
    }

    fileprivate static func hasAudio(_ samples: [Float]) -> Bool {
        guard samples.count >= 1_600 else { return false }
        var energy: Double = 0
        var finiteCount = 0
        for value in samples where value.isFinite {
            energy += Double(value) * Double(value)
            finiteCount += 1
        }
        return finiteCount > 0 && sqrt(energy / Double(finiteCount)) >= 0.0005
    }

    private static func readAudio(asset: AVAsset, track: AVAssetTrack,
                                  start: Double, end: Double) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhisperSpeechError.audioConversion }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000),
                                      duration: CMTime(seconds: end - start, preferredTimescale: 16_000))
        guard reader.startReading() else { throw reader.error ?? WhisperSpeechError.audioConversion }
        defer { reader.cancelReading() }
        var samples: [Float] = []
        samples.reserveCapacity(Int((end - start) * 16_000) + 4096)
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                throw WhisperSpeechError.audioConversion
            }
            let bytes = CMBlockBufferGetDataLength(block)
            guard bytes % MemoryLayout<Float>.size == 0 else { throw WhisperSpeechError.audioConversion }
            var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes { pointer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes,
                                           destination: pointer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw WhisperSpeechError.audioConversion }
            samples.append(contentsOf: values)
            guard samples.count <= 31 * 16_000 else { throw WhisperSpeechError.audioConversion }
        }
        if reader.status == .failed { throw reader.error ?? WhisperSpeechError.audioConversion }
        return samples
    }
}

/// 仅限制 SDK 的语言预测候选；所有文字编码、解码和词时间戳行为仍使用原 tokenizer。
private struct ChineseEnglishTokenizer: WhisperTokenizer {
    private let base: any WhisperTokenizer
    let allLanguageTokens: Set<Int>
    var specialTokens: SpecialTokens { base.specialTokens }

    init(base: any WhisperTokenizer) throws {
        guard let chinese = base.convertTokenToId("<|zh|>"),
              let english = base.convertTokenToId("<|en|>"),
              chinese != english,
              base.allLanguageTokens.contains(chinese),
              base.allLanguageTokens.contains(english) else {
            throw WhisperSpeechError.unsupportedModel
        }
        self.base = base
        allLanguageTokens = [chinese, english]
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        base.splitToWordTokens(tokenIds: tokenIds)
    }
}

/// SDK 1.1.1 在 temperature fallback 内再次检测语言。复用同一 encoder 的
/// 首次结果，让升温只修订文字、不重采语种；新 encoder 仍允许真实语言切换。
/// 委派既有 TextDecoder，不额外运行 audioEncoder、不修改已加载模型或 tokenizer 文本。
private final class StableChineseEnglishDecoder: TextDecoding {
    private let base: TextDecoder
    private var cachedEncoder: MLMultiArray?
    private var cachedLanguage: DecodingResult?

    init(base: TextDecoder) { self.base = base }

    var tokenizer: (any WhisperTokenizer)? {
        get { base.tokenizer }
        set { base.tokenizer = newValue }
    }
    var isModelMultilingual: Bool {
        get { base.isModelMultilingual }
        set { base.isModelMultilingual = newValue }
    }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var logitsFilters: [any LogitsFiltering]? {
        get { base.logitsFilters }
        set { base.logitsFilters = newValue }
    }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await base.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt initialPrompt: [Int]) throws -> any DecodingInputsType {
        try base.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(_ decoderInputs: any DecodingInputsType,
                              withOptions options: DecodingOptions?) async throws -> any DecodingInputsType {
        try await base.prefillDecoderInputs(decoderInputs, withOptions: options)
    }

    func decodeText(from encoderOutput: any AudioEncoderOutputType,
                    using decoderInputs: any DecodingInputsType, sampler tokenSampler: TokenSampling,
                    options decoderOptions: DecodingOptions,
                    callback: TranscriptionCallback?) async throws -> DecodingResult {
        try await base.decodeText(from: encoderOutput, using: decoderInputs,
                                  sampler: tokenSampler, options: decoderOptions, callback: callback)
    }

    func detectLanguage(from encoderOutput: any AudioEncoderOutputType,
                        using decoderInputs: any DecodingInputsType, sampler tokenSampler: TokenSampling,
                        options: DecodingOptions, temperature: FloatType) async throws -> DecodingResult {
        if let encoder = encoderOutput as? MLMultiArray, encoder === cachedEncoder,
           var cachedLanguage {
            // 缓存命中没有新推理，不能把第一次检测耗时再计入 fallback。
            cachedLanguage.timings = nil
            return cachedLanguage
        }
        let result = try await base.detectLanguage(
            from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
            options: options, temperature: temperature
        )
        cachedEncoder = encoderOutput as? MLMultiArray
        cachedLanguage = result
        return result
    }
}

/// 已有录音采集供应 PCM，不另外打开麦克风；每个来源独立缓冲，共享一个模型。
@MainActor
final class WhisperLiveRecognizer: ObservableObject {
    @Published private(set) var isRecognizing = false
    var onError: ((Error) -> Void)?

    private let service: WhisperSpeechService
    private var sessionID: UUID?
    private var source = ""
    private var terms: [String] = []
    private var restrictToChineseEnglish = false
    private var languageSelection = WhisperLanguageSelectionPolicy(locale: "zh-en")
    private var update: ((TranscriptSegment, Bool) -> Void)?
    private var epochs: [AudioEpoch] = []
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var timer: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingID: UUID?
    private var deadline: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var origin = Date()
    private static let sampleRate: Double = 16_000

    init(service: WhisperSpeechService) { self.service = service }

    func start(contextualStrings: [String], source: String, locale: String = "zh-en",
               onUpdate: @escaping (TranscriptSegment, Bool) -> Void) async throws {
        cancel()
        guard !service.loadedModelVariant.isEmpty else { throw WhisperSpeechError.modelUnavailable }
        self.source = source
        terms = contextualStrings
        restrictToChineseEnglish = WhisperSpeechService.isChineseEnglishLocale(locale)
        languageSelection = WhisperLanguageSelectionPolicy(locale: locale)
        update = onUpdate
        origin = Date()
        let id = UUID()
        sessionID = id
        isRecognizing = true
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_500_000_000) }
                catch { return }
                guard let self, self.sessionID == id else { return }
                self.scheduleProcessing()
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at timelineOffset: Double? = nil) {
        guard isRecognizing, buffer.frameLength > 0 else { return }
        do {
            var values = try convertedSamples(buffer)
            let offset = timelineOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
                ?? epochs.last.map { $0.offset + $0.end }
                ?? max(0, Date().timeIntervalSince(origin))
            var epoch: AudioEpoch
            if let last = epochs.last, !last.closed, offset - last.offset - last.end <= 3 {
                epoch = last
                let gap = offset - epoch.offset - epoch.end
                if gap > 0.02 {
                    epoch.samples.append(contentsOf: repeatElement(0, count: Int(gap * Self.sampleRate)))
                } else if gap < -0.05 {
                    values.removeFirst(min(values.count, Int(-gap * Self.sampleRate)))
                }
            } else {
                epochs.last?.closed = true
                epoch = AudioEpoch(offset: offset)
                epochs.append(epoch)
            }
            epoch.samples.append(contentsOf: values)
            // 明确暂停，不能在慢设备上无限累积内存或悄悄丢掉语音。
            if epochs.reduce(0, { $0 + $1.samples.count }) > 45 * 16_000 {
                isRecognizing = false
                epochs.last?.closed = true
                timer?.cancel()
                onError?(WhisperSpeechError.decodingBacklog)
            }
            if epoch.end - epoch.lastDecodedEnd >= 2.5 ||
                epoch.end >= epoch.coreStart + 15 || !isRecognizing {
                scheduleProcessing()
            }
        } catch {
            isRecognizing = false
            timer?.cancel()
            onError?(error)
        }
    }

    func finish() async {
        isRecognizing = false
        timer?.cancel()
        timer = nil
        epochs.last?.closed = true
        scheduleProcessing()
        guard !epochs.isEmpty || processingTask != nil else { return }
        let id = sessionID
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) }
            catch { return }
            guard let self, self.sessionID == id else { return }
            self.onError?(WhisperSpeechError.finishingTimedOut)
            self.cancel()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if epochs.isEmpty && processingTask == nil { continuation.resume() }
                else { finishWaiters.append(continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        sessionID = nil
        isRecognizing = false
        timer?.cancel(); timer = nil
        processingTask?.cancel(); processingTask = nil
        processingID = nil
        deadline?.cancel(); deadline = nil
        epochs.removeAll()
        converter = nil
        inputFormat = nil
        update = nil
        resolveFinish()
    }

    private func convertedSamples(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        if inputFormat != buffer.format {
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Self.sampleRate, channels: 1, interleaved: false),
                  let prepared = AVAudioConverter(from: buffer.format, to: target) else {
                throw WhisperSpeechError.audioConversion
            }
            converter = prepared
            inputFormat = buffer.format
        }
        guard let converter,
              let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength)
                    * Self.sampleRate / buffer.format.sampleRate) + 64)
              ) else { throw WhisperSpeechError.audioConversion }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, error == nil, let channel = output.floatChannelData?[0] else {
            if let error { throw error }
            throw WhisperSpeechError.audioConversion
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    private func scheduleProcessing() {
        guard processingTask == nil, let session = sessionID, !epochs.isEmpty else {
            resolveFinishIfDone()
            return
        }
        let id = UUID()
        let restrictToChineseEnglish = self.restrictToChineseEnglish
        let terms = self.terms
        processingID = id
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.processingID == id {
                    self.processingTask = nil
                    self.processingID = nil
                    self.resolveFinishIfDone()
                }
            }
            do {
                while !Task.isCancelled, self.sessionID == session, let epoch = self.epochs.first {
                    let complete = epoch.closed || epoch.end >= epoch.coreStart + 15
                    let coreEnd = min(epoch.end, epoch.coreStart + 12)
                    if coreEnd <= epoch.coreStart {
                        for sentence in epoch.sentences.finish(source: self.source) {
                            self.update?(sentence.segment, sentence.isFinal)
                        }
                        self.epochs.removeFirst()
                        continue
                    }
                    let audioStart = max(0, epoch.coreStart - 3)
                    let audioEnd = min(epoch.end, epoch.coreStart + 15)
                    let lower = max(0, Int((audioStart - epoch.bufferStart) * Self.sampleRate))
                    let upper = min(epoch.samples.count, Int((audioEnd - epoch.bufferStart) * Self.sampleRate))
                    guard upper > lower else { return }
                    let snapshot = Array(epoch.samples[lower..<upper])
                    let trailingSilenceFrom = WhisperDecodeSchedulingPolicy.trailingSilenceStart(
                        samples: snapshot, audioStart: epoch.offset + audioStart
                    )
                    guard epoch.decodeScheduling.nextDecision(
                        audioEnd: epoch.offset + audioEnd,
                        lastDecodedEnd: epoch.offset + epoch.lastDecodedEnd,
                        coreStart: epoch.offset + epoch.coreStart, complete: complete,
                        hasPendingSentence: epoch.sentences.hasPendingSentence,
                        hasTrailingSilence: trailingSilenceFrom != nil
                    ) != nil else { return }
                    epoch.lastDecodedEnd = audioEnd
                    var results = try await self.service.decode(
                        samples: snapshot, contextualStrings: terms,
                        language: self.languageSelection.language(
                            coreStart: epoch.offset + epoch.coreStart,
                            audioEnd: epoch.offset + audioEnd
                        ), restrictToChineseEnglish: restrictToChineseEnglish
                    )
                    try Task.checkCancellation()
                    guard self.sessionID == session else { return }
                    self.languageSelection.observe(
                        language: results.first?.language, coreStart: epoch.offset + epoch.coreStart,
                        audioEnd: epoch.offset + audioEnd
                    )
                    let publicationEnd = WhisperDecodeSchedulingPolicy.publicationEnd(
                        coreEnd: coreEnd, audioEnd: audioEnd, complete: complete,
                        hasTrailingSilence: trailingSilenceFrom != nil
                    )
                    var reconciled = epoch.reconciliation.reconcile(
                        words: WhisperSpeechService.absoluteWords(
                            from: results, offset: epoch.offset + audioStart
                        ), coreStart: epoch.offset + epoch.coreStart,
                        publicationEnd: epoch.offset + publicationEnd,
                        audioEnd: epoch.offset + audioEnd
                    )
                    if reconciled.requiresConfirmation {
                        results = try await self.service.decode(
                            samples: snapshot, contextualStrings: terms,
                            language: self.languageSelection.language(
                                coreStart: epoch.offset + epoch.coreStart,
                                audioEnd: epoch.offset + audioEnd
                            ), restrictToChineseEnglish: restrictToChineseEnglish
                        )
                        try Task.checkCancellation()
                        guard self.sessionID == session else { return }
                        reconciled = epoch.reconciliation.reconcile(
                            words: WhisperSpeechService.absoluteWords(
                                from: results, offset: epoch.offset + audioStart
                            ), coreStart: epoch.offset + epoch.coreStart,
                            publicationEnd: epoch.offset + publicationEnd,
                            audioEnd: epoch.offset + audioEnd, confirmed: true
                        )
                    }
                    self.publish(reconciled, epoch: epoch, audioEnd: audioEnd,
                                 coreEnd: publicationEnd, complete: complete,
                                 trailingSilenceFrom: trailingSilenceFrom)
                    if complete {
                        epoch.coreStart = coreEnd
                        if epoch.closed && epoch.coreStart >= epoch.end {
                            self.epochs.removeFirst()
                        } else {
                            let retainFrom = max(0, epoch.coreStart - 3)
                            let remove = min(epoch.samples.count,
                                             max(0, Int((retainFrom - epoch.bufferStart) * Self.sampleRate)))
                            epoch.samples.removeFirst(remove)
                            epoch.bufferStart += Double(remove) / Self.sampleRate
                            // 新正文已有部分音频，可尽快显示，不等下一次 timer。
                            epoch.lastDecodedEnd = epoch.coreStart
                        }
                    } else if epoch.closed || !self.isRecognizing {
                        // finish 可能发生在 partial 的模型 await 期间。
                        // 再取闭合快照处理尾音，不能让最后一个请求仅靠截止 timer 收尾。
                        continue
                    } else if trailingSilenceFrom != nil, epoch.sentences.hasPendingSentence,
                              epoch.end == audioEnd {
                        // 帧已停在同一真实静音快照时立即有限确认，避免再等下一次 timer。
                        // policy 每个 audioEnd 最多额外两次；新帧到达则退回常规调度。
                        continue
                    } else {
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                guard self.sessionID == session else { return }
                self.isRecognizing = false
                self.timer?.cancel()
                self.epochs.removeAll()
                self.onError?(error)
            }
        }
    }

    private func publish(_ snapshot: WhisperWindowReconciliationPolicy.Snapshot, epoch: AudioEpoch,
                         audioEnd: Double, coreEnd: Double, complete: Bool,
                         trailingSilenceFrom: Double?) {
        let changes = epoch.sentences.update(
            words: snapshot.words, replacingFrom: epoch.offset + epoch.coreStart,
            observedThrough: epoch.offset + audioEnd,
            stableThrough: epoch.offset + (complete ? coreEnd : epoch.coreStart),
            followingWord: snapshot.followingWord,
            trailingSilenceFrom: trailingSilenceFrom, source: source,
            finishing: complete && epoch.closed && coreEnd >= epoch.end
        )
        for change in changes {
            update?(change.segment, change.isFinal)
        }
    }

    private func resolveFinishIfDone() {
        if !isRecognizing && epochs.isEmpty && processingTask == nil {
            deadline?.cancel(); deadline = nil
            resolveFinish()
        }
    }

    private func resolveFinish() {
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
private final class AudioEpoch {
    let offset: Double
    var samples: [Float] = []
    var bufferStart: Double = 0
    var coreStart: Double = 0
    var lastDecodedEnd: Double = 0
    var closed = false
    var sentences = TranscriptSentenceAssembler()
    var decodeScheduling = WhisperDecodeSchedulingPolicy()
    var reconciliation = WhisperWindowReconciliationPolicy()
    var end: Double { bufferStart + Double(samples.count) / 16_000 }
    init(offset: Double) { self.offset = offset }
}

#endif
