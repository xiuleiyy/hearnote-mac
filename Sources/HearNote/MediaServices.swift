import AppKit
import AVFoundation
import Combine
import Foundation
import HearNoteCore
import Speech

enum MediaServiceError: LocalizedError {
    case microphonePermission
    case speechPermission
    case localRecognitionUnavailable(String)
    case speechUnavailable
    case noAudio
    case invalidDuration
    case recordingUnavailable
    case exportFailed(String)
    case timedOut(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphonePermission:
            return "无法访问麦克风。请在系统设置 → 隐私与安全性 → 麦克风中允许听记。"
        case .speechPermission:
            return "语音识别权限未开启。请在系统设置 → 隐私与安全性 → 语音识别中允许听记。"
        case .localRecognitionUnavailable(let locale):
            return "此 Mac 当前不支持 \(locale) 的本地语音识别。可换一种语言，或在设置里明确允许 Apple 在线识别。"
        case .speechUnavailable:
            return "Apple 语音识别目前不可用，请检查网络或稍后重试。"
        case .noAudio:
            return "文件没有可读取的音轨。请使用含声音的音频或视频文件。"
        case .invalidDuration:
            return "无法读取文件时长，文件可能损坏或仍在写入。"
        case .recordingUnavailable:
            return "麦克风无法开始录音，请检查输入设备是否可用。"
        case .exportFailed(let message):
            return "音频分段失败：\(message)"
        case .timedOut(let action):
            return "\(action)超时，请重试。已经识别的文字可保留。"
        case .recognitionFailed(let message):
            return "语音识别失败：\(message)"
        }
    }
}

@MainActor
final class MediaPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var player: AVPlayer?
    @Published private(set) var errorMessage: String?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?
    private var generation = UUID()
    private var playbackRate: Float = 1

    func load(url: URL?) {
        cleanup()
        generation = UUID()
        currentTime = 0
        duration = 0
        errorMessage = nil
        guard let url else { return }
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        let expectedGeneration = generation
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.generation == expectedGeneration else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = max(0, seconds) }
                self.isPlaying = self.player?.timeControlStatus == .playing
                if let error = self.player?.currentItem?.error {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == expectedGeneration else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
        durationTask = Task { [weak self] in
            do {
                let time = try await asset.load(.duration)
                guard let self, !Task.isCancelled,
                      self.generation == expectedGeneration else { return }
                if time.seconds.isFinite { self.duration = max(0, time.seconds) }
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let clamped = duration > 0 ? min(duration, max(0, seconds)) : max(0, seconds)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func setRate(_ rate: Float) {
        guard rate.isFinite, rate >= 0.5, rate <= 3 else { return }
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    func stop() {
        player?.pause()
        isPlaying = false
        seek(to: 0)
    }

    private func cleanup() {
        durationTask?.cancel()
        durationTask = nil
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        isPlaying = false
    }

    deinit {
        durationTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }
}

/// 单次麦克风采集同时写文件和供应实时识别，不另开第二个输入流。
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var errorMessage: String?
    private(set) var firstBufferHostTime: Double?

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private var engine: AVAudioEngine?
    private var sink: RecordingSink?
    private var captureID: UUID?
    private var startupID: UUID?
    private var lastFinishedURL: URL?
    private var configurationObserver: NSObjectProtocol?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification, object: nil
        )
    }

    func start(in directory: URL) async throws {
        guard !isRecording else { return }
        guard startupID == nil else { throw MediaServiceError.recordingUnavailable }
        let starting = UUID()
        startupID = starting
        defer { if startupID == starting { startupID = nil } }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw MediaServiceError.microphonePermission }
        default:
            throw MediaServiceError.microphonePermission
        }
        try Task.checkCancellation()
        guard startupID == starting else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recording-\(UUID().uuidString).caf")
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MediaServiceError.recordingUnavailable
        }
        let newSink = try RecordingSink(url: url, format: format)
        let id = UUID()
        errorMessage = nil
        elapsed = 0
        level = 0
        firstBufferHostTime = nil
        lastFinishedURL = nil
        captureID = id
        sink = newSink
        engine = newEngine
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
            let hostTime = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            let result = newSink.consume(buffer, hostTime: hostTime)
            Task { @MainActor in
                guard let self, self.captureID == id else { return }
                if self.firstBufferHostTime == nil { self.firstBufferHostTime = hostTime }
                self.elapsed = result.elapsed
                self.level = result.level
                if let error = result.error {
                    self.errorMessage = "录音写入失败：\(error.localizedDescription)"
                    _ = self.stop()
                    self.onError?(error)
                    return
                }
                if let copiedBuffer = result.buffer { self.onBuffer?(copiedBuffer) }
            }
        }
        do {
            newEngine.prepare()
            try newEngine.start()
            isRecording = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.captureID == id, self.isRecording else { return }
                    let error = MediaServiceError.recordingUnavailable
                    self.errorMessage = "输入设备发生变化，录音已停止；已录内容已保留。"
                    _ = self.stop()
                    self.onError?(error)
                }
            }
        } catch {
            newEngine.stop()
            input.removeTap(onBus: 0)
            newSink.close()
            engine = nil
            sink = nil
            captureID = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @discardableResult
    func stop() -> URL? {
        startupID = nil
        guard let engine else { return lastFinishedURL }
        captureID = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let url = sink?.url
        sink?.close()
        sink = nil
        self.engine = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        isRecording = false
        level = 0
        lastFinishedURL = url
        return url
    }

    func cancel() {
        let url = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        lastFinishedURL = nil
        elapsed = 0
    }

    @objc private func applicationWillTerminate(_ notification: Notification) {
        _ = stop()
    }

    deinit {
        engine?.stop()
        sink?.close()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }
}

/// 仅在音频回调中写盘；复制的 buffer 才可交给主线程，tap 的原 buffer 会被复用。
private final class RecordingSink: @unchecked Sendable {
    struct Result {
        let buffer: AVAudioPCMBuffer?
        let level: Double
        let elapsed: Double
        let error: Error?
    }

    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private let sampleRate: Double
    private var firstHostTime: Double?
    private var failed = false

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        sampleRate = format.sampleRate
        file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    func consume(_ buffer: AVAudioPCMBuffer, hostTime: Double) -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard let file, !failed else {
            return Result(buffer: nil, level: 0,
                          elapsed: Double(frames) / sampleRate, error: nil)
        }
        do {
            if firstHostTime == nil { firstHostTime = hostTime }
            if let firstHostTime {
                let gap = hostTime - firstHostTime - Double(frames) / sampleRate
                if gap > 0.02 {
                    try appendSilence(frames: AVAudioFramePosition((gap * sampleRate).rounded()),
                                      format: buffer.format, file: file)
                } else if gap < -0.25 {
                    throw MediaServiceError.recordingUnavailable
                }
            }
            try file.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            return Result(buffer: Self.copy(buffer), level: Self.rms(buffer),
                          elapsed: Double(frames) / sampleRate, error: nil)
        } catch {
            failed = true
            return Result(buffer: nil, level: 0,
                          elapsed: Double(frames) / sampleRate, error: error)
        }
    }

    func close() {
        lock.lock()
        file = nil
        lock.unlock()
    }

    private func appendSilence(frames missingFrames: AVAudioFramePosition,
                               format: AVAudioFormat, file: AVAudioFile) throws {
        guard missingFrames > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { return }
        var remaining = missingFrames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(8192, remaining))
            silence.frameLength = count
            for audioBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            try file.write(from: silence)
            frames += AVAudioFramePosition(count)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                         frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData else { continue }
            let count = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(dst, src, Int(count))
        }
        return copy
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Double = 0
        for index in 0..<count {
            let value = Double(data[0][index * Int(buffer.stride)])
            sum += value * value
        }
        return min(1, sqrt(sum / Double(count)) * 4)
    }
}

@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress: Double = 0
    /// 识别失败或取消时，不让已经完成的前半段文字消失。
    @Published private(set) var partialSegments: [TranscriptSegment] = []
    var contextualStrings: [String] = []

    private var runID: UUID?
    private var activeRecognition: FileRecognitionOperation?
    private var activeExport: AudioExportOperation?

    func transcribe(url: URL, locale: String, allowCloudRecognition: Bool,
                    contextualStrings: [String]? = nil) async throws -> [TranscriptSegment] {
        guard !isTranscribing else {
            throw MediaServiceError.recognitionFailed("已有转写任务进行中。")
        }
        let id = UUID()
        let terms = contextualStrings ?? self.contextualStrings
        runID = id
        isTranscribing = true
        progress = 0
        partialSegments = []
        defer {
            if runID == id {
                runID = nil
                activeRecognition = nil
                activeExport = nil
                isTranscribing = false
            }
        }
        return try await withTaskCancellationHandler {
            try await performTranscription(url: url, locale: locale,
                                           allowCloudRecognition: allowCloudRecognition,
                                           contextualStrings: terms, id: id)
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.runID == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        runID = nil
        activeRecognition?.cancel()
        activeExport?.cancel()
        activeRecognition = nil
        activeExport = nil
        isTranscribing = false
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id else { throw CancellationError() }
    }

    private func performTranscription(url: URL, locale: String, allowCloudRecognition: Bool,
                                      contextualStrings: [String], id: UUID) async throws
        -> [TranscriptSegment] {
        let recognizer = try await SpeechPermissions.recognizer(
            locale: locale, allowCloudRecognition: allowCloudRecognition
        )
        try checkRun(id)
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw MediaServiceError.noAudio }
        let assetDuration = try await asset.load(.duration)
        let total = assetDuration.seconds
        guard total.isFinite, total > 0 else { throw MediaServiceError.invalidDuration }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearnote-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        // 43 秒正文 + 两边最多各 1 秒上下文，单次始终 ≤45 秒。
        // 按词的时间中点归属正文，减少断句边界的遗漏和重复。
        var coreStart: Double = 0
        while coreStart < total {
            try checkRun(id)
            let coreEnd = min(total, coreStart + 43)
            let audioStart = max(0, coreStart - 1)
            let audioEnd = min(total, coreEnd + 1)
            let chunkURL = temporaryDirectory.appendingPathComponent("chunk-\(Int(coreStart)).m4a")
            guard let exporter = AVAssetExportSession(asset: asset,
                                                      presetName: AVAssetExportPresetAppleM4A) else {
                throw MediaServiceError.exportFailed("此文件无法转换为识别用音频。")
            }
            exporter.outputURL = chunkURL
            exporter.outputFileType = .m4a
            exporter.timeRange = CMTimeRange(
                start: CMTime(seconds: audioStart, preferredTimescale: 600),
                duration: CMTime(seconds: audioEnd - audioStart, preferredTimescale: 600)
            )
            let exportOperation = AudioExportOperation(session: exporter)
            activeExport = exportOperation
            try await exportOperation.run()
            activeExport = nil
            try checkRun(id)

            let operation = FileRecognitionOperation()
            activeRecognition = operation
            let result = try await operation.run(
                recognizer: recognizer, url: chunkURL,
                requiresOnDevice: !allowCloudRecognition,
                contextualStrings: contextualStrings,
                offset: audioStart, coreStart: coreStart, coreEnd: coreEnd
            )
            activeRecognition = nil
            try checkRun(id)
            partialSegments.append(contentsOf: result)
            progress = coreEnd / total
            try? FileManager.default.removeItem(at: chunkURL)
            coreStart = coreEnd
        }
        progress = 1
        return partialSegments
    }
}

@MainActor
enum SpeechPermissions {
    static func recognizer(locale: String, allowCloudRecognition: Bool) async throws
        -> SFSpeechRecognizer {
        let authorization: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            authorization = SFSpeechRecognizer.authorizationStatus()
        }
        guard authorization == .authorized else { throw MediaServiceError.speechPermission }
        try Task.checkCancellation()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw MediaServiceError.localRecognitionUnavailable(locale)
        }
        if !allowCloudRecognition, !recognizer.supportsOnDeviceRecognition {
            throw MediaServiceError.localRecognitionUnavailable(locale)
        }
        if allowCloudRecognition, !recognizer.isAvailable {
            throw MediaServiceError.speechUnavailable
        }
        return recognizer
    }
}

@MainActor
private final class AudioExportOperation {
    private let session: AVAssetExportSession
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var completed = false
    private var cancelled = false

    init(session: AVAssetExportSession) { self.session = session }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard !cancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            session.exportAsynchronously { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    switch self.session.status {
                    case .completed: self.finish()
                    case .cancelled: self.finish(error: CancellationError())
                    default:
                        let message = self.session.error?.localizedDescription ?? "无法导出音轨。"
                        self.finish(error: MediaServiceError.exportFailed(message))
                    }
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) }
                catch { return }
                guard let self, !self.completed else { return }
                self.session.cancelExport()
                self.finish(error: MediaServiceError.timedOut("音频分段"))
            }
        }
    }

    func cancel() {
        cancelled = true
        session.cancelExport()
        finish(error: CancellationError())
    }

    private func finish(error: Error? = nil) {
        guard !completed else { return }
        completed = true
        deadline?.cancel()
        deadline = nil
        let continuation = continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

@MainActor
private final class FileRecognitionOperation {
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var deadline: Task<Void, Never>?
    private var completed = false
    private var cancelled = false

    func run(recognizer: SFSpeechRecognizer, url: URL, requiresOnDevice: Bool,
             contextualStrings: [String], offset: Double, coreStart: Double, coreEnd: Double)
        async throws -> [TranscriptSegment] {
        try await withCheckedThrowingContinuation { continuation in
            guard !cancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = requiresOnDevice
            request.addsPunctuation = true
            request.taskHint = .dictation
            request.contextualStrings = Array(contextualStrings.prefix(100))
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, !self.completed else { return }
                    if let result, result.isFinal {
                        self.finish(.success(Self.paragraphs(
                            result.bestTranscription, offset: offset,
                            coreStart: coreStart, coreEnd: coreEnd
                        )))
                    } else if let error {
                        self.finish(.failure(MediaServiceError.recognitionFailed(error.localizedDescription)))
                    }
                }
            }
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 75_000_000_000) }
                catch { return }
                guard let self, !self.completed else { return }
                self.task?.cancel()
                self.finish(.failure(MediaServiceError.timedOut("语音识别")))
            }
        }
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[TranscriptSegment], Error>) {
        guard !completed else { return }
        completed = true
        deadline?.cancel()
        deadline = nil
        task = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    private static func paragraphs(_ transcription: SFTranscription, offset: Double,
                                   coreStart: Double, coreEnd: Double) -> [TranscriptSegment] {
        let allWords = transcription.segments
        let ownedIndices = allWords.indices.filter { index in
            let word = allWords[index]
            let midpoint = offset + word.timestamp + word.duration / 2
            return midpoint >= coreStart && midpoint < coreEnd
        }
        guard !ownedIndices.isEmpty else { return [] }
        var groups: [[Int]] = []
        var current: [Int] = []
        for index in ownedIndices {
            if let first = current.first, let previous = current.last {
                let currentDuration = allWords[index].timestamp - allWords[first].timestamp
                let gap = allWords[index].timestamp -
                    (allWords[previous].timestamp + allWords[previous].duration)
                let characterCount = NSMaxRange(allWords[index].substringRange) -
                    allWords[first].substringRange.location
                if gap > 0.8 || currentDuration >= 9 || characterCount > 64 {
                    groups.append(current)
                    current = []
                }
            }
            current.append(index)
        }
        if !current.isEmpty { groups.append(current) }
        let formatted = transcription.formattedString as NSString
        return groups.compactMap { indices in
            guard let firstIndex = indices.first, let lastIndex = indices.last else { return nil }
            let first = allWords[firstIndex]
            let last = allWords[lastIndex]
            let startIndex = first.substringRange.location
            let endIndex = lastIndex + 1 < allWords.count
                ? allWords[lastIndex + 1].substringRange.location : formatted.length
            guard startIndex >= 0, endIndex >= startIndex, endIndex <= formatted.length else {
                return nil
            }
            let text = formatted.substring(with: NSRange(location: startIndex,
                                                        length: endIndex - startIndex))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(start: max(0, offset + first.timestamp),
                                     end: min(coreEnd + 1, offset + last.timestamp + last.duration),
                                     text: text)
        }
    }
}
