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
        if kit != nil, loadedModelVariant == modelVariant, modelFolder == nil { return }
        if preparationTask != nil, let currentID = preparationID {
            guard preparingVariant == modelVariant, preparingFolder == modelFolder else {
                throw WhisperSpeechError.preparationBusy
            }
            guard cancelledPreparationID != currentID else {
                throw WhisperSpeechError.preparationBusy
            }
            return try await awaitPreparation(id: currentID)
        }
        guard decodeTail == nil, !isTranscribing else { throw WhisperSpeechError.decoderBusy }
        if let folder = modelFolder {
            let required = ["tokenizer.json", "tokenizer_config.json"]
            guard required.allSatisfy({
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
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            var outcome: Result<Void, Error> = .failure(CancellationError())
            defer {
                if self.preparationID == id {
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
            let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
            let cache = support.appendingPathComponent("HearNote/WhisperModels", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let folderKey = "HearNote.whisper.folder.\(modelVariant)"
            let savedPath = UserDefaults.standard.string(forKey: folderKey)
            let cachedFolder = savedPath.flatMap { path -> URL? in
                FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
            }
            let folder = modelFolder ?? cachedFolder
            self.modelStatus = folder == nil
                ? "正在下载并准备 \(modelVariant)，首次使用需要模型和 tokenizer"
                : "正在加载本地 \(modelVariant)"
            // 切换时先释放旧模型，降低两个完整模型同时占用内存的峰值。
            self.kit = nil
            self.loadedModelVariant = ""
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
                    model: modelVariant, downloadBase: cache, modelFolder: folder?.path,
                    computeOptions: computeOptions,
                    verbose: false, prewarm: true, load: true, download: folder == nil
                ))
                try Task.checkCancellation()
                guard self.preparationID == id, self.cancelledPreparationID != id else {
                    throw CancellationError()
                }
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
                outcome = .failure(error)
                if self.preparationID == id {
                    self.modelStatus = "模型准备失败，可检查网络或导入完整本地模型目录"
                }
                throw error
            }
        }
        preparationTask = task
        try await awaitPreparation(id: id)
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
                    modelVariant: String = WhisperSpeechService.defaultModelVariant) async throws
        -> [TranscriptSegment] {
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
            while start < duration {
                try self.checkFileRun(id)
                let end = min(duration, start + 24)
                let audioStart = max(0, start - 3)
                let audioEnd = min(duration, end + 3)
                let samples = try Self.readAudio(asset: asset, track: track,
                                                start: audioStart, end: audioEnd)
                let results = try await self.decode(samples: samples,
                                                    contextualStrings: contextualStrings)
                try self.checkFileRun(id)
                let pieces = Self.words(from: results)
                    .filter { word in
                        let midpoint = audioStart + (word.start + word.end) / 2
                        return midpoint >= start && midpoint < end
                    }
                if !pieces.isEmpty {
                    // 保持短段和时间戳；按实际词时间，而非模型窗口时长归属正文。
                    let groups = Dictionary(grouping: pieces) {
                        Int(max(0, audioStart + $0.start) / 5)
                    }
                    for bucket in groups.keys.sorted() {
                        guard let words = groups[bucket],
                              let first = words.first, let last = words.last else { continue }
                        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            self.partialSegments.append(TranscriptSegment(
                                start: audioStart + first.start,
                                end: max(audioStart + first.start + 0.01, audioStart + last.end),
                                text: text
                            ))
                        }
                    }
                }
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

    fileprivate func decode(samples: [Float], contextualStrings: [String]) async throws
        -> [TranscriptionResult] {
        try Task.checkCancellation()
        guard let kit else { throw WhisperSpeechError.modelUnavailable }
        guard Self.hasAudio(samples) else { return [] }
        let predecessor = decodeTail
        let id = UUID()
        let task = Task { @MainActor () throws -> [TranscriptionResult] in
            if let predecessor { _ = try? await predecessor.value }
            try Task.checkCancellation()
            var options = DecodingOptions(
                verbose: false, task: .transcribe, language: nil,
                temperature: 0, temperatureFallbackCount: 1,
                usePrefillPrompt: true, detectLanguage: true,
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

    fileprivate struct TimedWord {
        let start: Double
        let end: Double
        let text: String
    }

    fileprivate static func words(from results: [TranscriptionResult]) -> [TimedWord] {
        results.flatMap(\.segments).flatMap { segment -> [TimedWord] in
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
        }.sorted { $0.start < $1.start }
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

/// 已有录音采集供应 PCM，不另外打开麦克风；每个来源独立缓冲，共享一个模型。
@MainActor
final class WhisperLiveRecognizer: ObservableObject {
    @Published private(set) var isRecognizing = false
    var onError: ((Error) -> Void)?

    private let service: WhisperSpeechService
    private var sessionID: UUID?
    private var source = ""
    private var terms: [String] = []
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

    func start(contextualStrings: [String], source: String,
               onUpdate: @escaping (TranscriptSegment, Bool) -> Void) async throws {
        cancel()
        guard !service.loadedModelVariant.isEmpty else { throw WhisperSpeechError.modelUnavailable }
        self.source = source
        terms = contextualStrings
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
                        self.epochs.removeFirst()
                        continue
                    }
                    guard complete || epoch.end - epoch.lastDecodedEnd >= 2.5 else { return }
                    let audioStart = max(0, epoch.coreStart - 3)
                    let audioEnd = min(epoch.end, epoch.coreStart + 15)
                    let lower = max(0, Int((audioStart - epoch.bufferStart) * Self.sampleRate))
                    let upper = min(epoch.samples.count, Int((audioEnd - epoch.bufferStart) * Self.sampleRate))
                    guard upper > lower else { return }
                    let snapshot = Array(epoch.samples[lower..<upper])
                    epoch.lastDecodedEnd = audioEnd
                    let results = try await self.service.decode(samples: snapshot, contextualStrings: self.terms)
                    try Task.checkCancellation()
                    guard self.sessionID == session else { return }
                    self.publish(results, epoch: epoch, audioStart: audioStart,
                                 coreEnd: coreEnd, complete: complete)
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
                            // 已提交正文由文档保存，只保留当前可修订窗口的辅助状态。
                            epoch.latest = epoch.latest.filter { Double($0.key * 3) >= epoch.coreStart }
                            epoch.segmentIDs = epoch.segmentIDs.filter { Double($0.key * 3) >= epoch.coreStart }
                            // 新正文已有部分音频，可尽快显示，不等下一次 timer。
                            epoch.lastDecodedEnd = epoch.coreStart
                        }
                    } else if epoch.closed || !self.isRecognizing {
                        // finish 可能发生在 partial 的模型 await 期间。
                        // 再取闭合快照处理尾音，不能让最后一个请求仅靠截止 timer 收尾。
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

    private func publish(_ results: [TranscriptionResult], epoch: AudioEpoch,
                         audioStart: Double, coreEnd: Double, complete: Bool) {
        let words = WhisperSpeechService.words(from: results).filter {
            let midpoint = audioStart + ($0.start + $0.end) / 2
            return midpoint >= epoch.coreStart && midpoint < coreEnd
        }
        let groups = Dictionary(grouping: words) {
            Int(max(0, audioStart + ($0.start + $0.end) / 2) / 3)
        }
        let currentBuckets = Set(groups.keys)
        // 删除当前可修订窗口中已经消失的 partial，避免留下错误临时文字。
        for bucket in epoch.latest.keys.sorted() {
            guard let previous = epoch.latest[bucket],
                  Double(bucket * 3) >= epoch.coreStart, !currentBuckets.contains(bucket) else { continue }
            var removed = previous.segment
            removed.text = ""
            update?(removed, false)
            epoch.latest.removeValue(forKey: bucket)
        }
        for bucket in groups.keys.sorted() {
            guard let pieces = groups[bucket], let first = pieces.first, let last = pieces.last else { continue }
            let text = pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let id = epoch.segmentIDs[bucket] ?? UUID()
            epoch.segmentIDs[bucket] = id
            let segment = TranscriptSegment(
                id: id, start: epoch.offset + audioStart + first.start,
                end: max(epoch.offset + audioStart + first.start + 0.01,
                         epoch.offset + audioStart + last.end),
                text: text, source: source
            )
            let finalized = complete || bucket != groups.keys.max()
            if epoch.latest[bucket]?.segment != segment ||
                epoch.latest[bucket]?.finalized != finalized {
                epoch.latest[bucket] = LiveChunk(segment: segment, finalized: finalized)
                update?(segment, finalized)
            }
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
    var segmentIDs: [Int: UUID] = [:]
    var latest: [Int: LiveChunk] = [:]
    var end: Double { bufferStart + Double(samples.count) / 16_000 }
    init(offset: Double) { self.offset = offset }
}

private struct LiveChunk {
    let segment: TranscriptSegment
    let finalized: Bool
}
#endif
