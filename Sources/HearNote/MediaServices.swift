import AppKit
import AVFoundation
import Combine
import Foundation
import HearNoteCore
import OSLog
import Speech

enum AppleSpeechAvailability {
    static var usesAnalyzer: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }
}

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
            return "无法访问麦克风。请在系统设置 → 隐私与安全性 → 麦克风中允许听译。"
        case .speechPermission:
            return "语音识别权限未开启。请在系统设置 → 隐私与安全性 → 语音识别中允许听译。"
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

/// 将 observer 与注册它的播放器一起持有；析构时不读取 UI 对象的 actor 隔离状态。
private final class MediaPlayerResources {
    private let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?

    init(player: AVPlayer, timeObserver: Any, endObserver: NSObjectProtocol,
         durationTask: Task<Void, Never>) {
        self.player = player
        self.timeObserver = timeObserver
        self.endObserver = endObserver
        self.durationTask = durationTask
    }

    /// 正常换文件时立即清理；清空 token，避免后续析构再次移除。
    @MainActor
    func invalidate() {
        durationTask?.cancel()
        durationTask = nil
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    deinit {
        durationTask?.cancel()
        // 最后一次 release 可能来自任意线程。只移交资源快照，不捕获正在析构的 self。
        guard timeObserver != nil || endObserver != nil else { return }
        let retainedPlayer = player
        let remainingTimeObserver = timeObserver
        let remainingEndObserver = endObserver
        DispatchQueue.main.async {
            retainedPlayer.pause()
            if let remainingTimeObserver {
                retainedPlayer.removeTimeObserver(remainingTimeObserver)
            }
            if let remainingEndObserver {
                NotificationCenter.default.removeObserver(remainingEndObserver)
            }
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

    private var resources: MediaPlayerResources?
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
        let timeObserver = newPlayer.addPeriodicTimeObserver(
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
        let endObserver = NotificationCenter.default.addObserver(
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
        let durationTask = Task { [weak self] in
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
        resources = MediaPlayerResources(
            player: newPlayer, timeObserver: timeObserver, endObserver: endObserver,
            durationTask: durationTask
        )
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
        resources?.invalidate()
        resources = nil
        player = nil
        isPlaying = false
    }
}

private struct AudioRouteRecoveryFailure: LocalizedError {
    var errorDescription: String? {
        "音频设备切换后，麦克风未能恢复。录音已停止，已录内容会保留；请检查当前输入设备后重新开始。"
    }
}

/// 单次会议保留同一个文件；耳机切换只重建硬件输入，不结束识别或翻译。
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var recoveryStatus = ""
    private(set) var firstBufferHostTime: Double?

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onCapturedBuffer: (@Sendable (AVAudioPCMBuffer, Double) -> Void)?
    var onError: ((Error) -> Void)?
    var onRecoveryStatusChanged: ((String) -> Void)?
    var onRouteChanged: (() -> Void)?

    private var engine: AVAudioEngine?
    private var engineInputID: UUID?
    private var sink: RecordingSink?
    private var captureID: UUID?
    private var startupID: UUID?
    private var lastFinishedURL: URL?
    private var configurationObserver: NSObjectProtocol?
    private var route = AudioRouteRecovery()
    private var recoveryTask: Task<Void, Never>?
    private var recoveryTaskID: UUID?
    private var isStopping = false

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
        case .authorized: break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw MediaServiceError.microphonePermission }
        default: throw MediaServiceError.microphonePermission
        }
        try Task.checkCancellation()
        guard startupID == starting else { throw CancellationError() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recording-\(UUID().uuidString).caf")
        let newEngine = AVAudioEngine()
        let format = newEngine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw MediaServiceError.recordingUnavailable
        }
        let newSink = try RecordingSink(url: url, format: format, onCapturedBuffer: onCapturedBuffer)
        let session = UUID()
        let input = route.start()
        errorMessage = nil
        elapsed = 0
        level = 0
        firstBufferHostTime = nil
        lastFinishedURL = nil
        setRecoveryStatus("")
        captureID = session
        sink = newSink
        do {
            try installHardware(newEngine, input: input, session: session, sink: newSink)
            isRecording = true
        } catch {
            try? retireHardware()
            try? newSink.close()
            route.stop()
            sink = nil
            captureID = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func installHardware(_ newEngine: AVAudioEngine, input id: UUID,
                                 session: UUID, sink: RecordingSink) throws {
        let node = newEngine.inputNode
        let nativeFormat = node.outputFormat(forBus: 0)
        try sink.activateInput(id, format: nativeFormat)
        engine = newEngine
        engineInputID = id
        // Observe before start: a route can change during hardware startup.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in
            // Apple advises against destroying the engine synchronously in its
            // configuration notification. Retire on a later main-actor turn.
            Task { @MainActor in self?.configurationChanged(session: session, input: id) }
        }
        node.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, time in
            let hostTime = time.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: time.hostTime)
                : ProcessInfo.processInfo.systemUptime
            sink.consume(buffer, hostTime: hostTime, input: id) {
                DispatchQueue.main.async {
                    guard let self, self.captureID == session else { return }
                    for result in sink.takePendingResults() {
                        guard self.captureID == session else { break }
                        self.receive(result, input: result.inputID)
                    }
                }
            }
        }
        newEngine.prepare()
        try newEngine.start()
    }

    private func receive(_ result: RecordingSink.Result, input id: UUID) {
        if let error = result.error {
            failRecording(error, message: "录音写入失败：\(error.localizedDescription)")
            return
        }
        guard let buffer = result.buffer else { return }
        if firstBufferHostTime == nil { firstBufferHostTime = result.hostTime }
        elapsed = max(elapsed, result.elapsed)
        level = result.level
        // engine.start alone does not prove an input is supplying audio.
        if engineInputID == id, route.accepts(input: id),
           let recovery = route.recoveryID,
           route.succeeded(recovery: recovery, input: id, activeHardwareInput: engineInputID) {
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryTaskID = nil
            setRecoveryStatus("麦克风已恢复，录音继续")
        }
        onBuffer?(buffer)
    }

    private func configurationChanged(session: UUID, input: UUID) {
        guard captureID == session, isRecording,
              let recovery = route.configurationChanged(input: input) else { return }
        do { try retireHardware() }
        catch {
            failRecording(error, message: "录音写入失败：\(error.localizedDescription)")
            return
        }
        guard captureID == session, isRecording, route.recoveryID == recovery else { return }
        // Retired converter tails have already reached the echo queue.
        onRouteChanged?()
        setRecoveryStatus("音频设备已切换，正在恢复麦克风；录音继续")
        guard recoveryTaskID == nil else { return }
        recoveryTaskID = recovery
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryTaskID == recovery {
                    self.recoveryTask = nil
                    self.recoveryTaskID = nil
                }
            }
            let delays: [UInt64] = [200_000_000, 300_000_000, 500_000_000,
                                    800_000_000, 1_200_000_000, 1_500_000_000]
            for delay in delays {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
                guard self.captureID == session, self.isRecording,
                      self.route.recoveryID == recovery, !Task.isCancelled,
                      let sink = self.sink else { return }
                if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                    self.failRecording(MediaServiceError.microphonePermission,
                                       message: MediaServiceError.microphonePermission.localizedDescription)
                    return
                }
                guard let input = self.route.nextAttempt(recovery: recovery) else { break }
                do {
                    try self.installHardware(AVAudioEngine(), input: input, session: session, sink: sink)
                    // A running but silent/stalled graph gets a finite retry.
                    // Digital-zero PCM counts as a working microphone stream.
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch is CancellationError { return }
                catch {
                    // Native startup failure is transient during route changes.
                    // A write/converter-tail error in retirement remains fatal.
                }
                guard self.captureID == session, self.isRecording,
                      self.route.recoveryID == recovery, !Task.isCancelled else { return }
                do { try self.retireHardware() }
                catch {
                    self.failRecording(error, message: "录音写入失败：\(error.localizedDescription)")
                    return
                }
                guard self.captureID == session, self.isRecording,
                      self.route.recoveryID == recovery, !Task.isCancelled else { return }
                self.route.attemptFailed(recovery: recovery, input: input)
            }
            guard self.captureID == session, self.route.recoveryID == recovery,
                  !Task.isCancelled else { return }
            self.failRecording(AudioRouteRecoveryFailure(),
                               message: AudioRouteRecoveryFailure().localizedDescription)
        }
    }

    private func retireHardware() throws {
        let retired = engine
        let input = engineInputID
        engine = nil
        engineInputID = nil
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        defer {
            retired?.stop()
            retired?.inputNode.removeTap(onBus: 0)
        }
        if let input, let sink {
            for result in try sink.retireInput(input) {
                guard captureID != nil else { break }
                receive(result, input: result.inputID)
            }
        } else if let sink {
            for result in sink.takePendingResults() {
                guard captureID != nil else { break }
                receive(result, input: result.inputID)
            }
        }
    }

    private func setRecoveryStatus(_ status: String) {
        recoveryStatus = status
        onRecoveryStatusChanged?(status)
    }

    private func failRecording(_ error: Error, message: String) {
        guard captureID != nil else { return }
        errorMessage = message
        // MeetingRecorder reads this warning after explicit Stop. It must not
        // re-enter the meeting's stop operation while flushing its last PCM.
        if isStopping { return }
        _ = stop()
        onError?(error)
    }

    @discardableResult
    func stop() -> URL? {
        guard !isStopping else { return sink?.url ?? lastFinishedURL }
        isStopping = true
        defer { isStopping = false }
        startupID = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryTaskID = nil
        route.stop()
        isRecording = false
        // Recovery can temporarily have no engine; the same sink still owns
        // the complete recording and must always be closed on explicit Stop.
        guard let sink else {
            captureID = nil
            return lastFinishedURL
        }
        let url = sink.url
        do {
            try retireHardware()
            for result in try sink.close() { receive(result, input: result.inputID) }
        } catch {
            errorMessage = "录音最后一段写入失败：\(error.localizedDescription)"
            try? sink.close()
        }
        if firstBufferHostTime == nil { firstBufferHostTime = sink.capturedStartHostTime }
        route.stop()
        captureID = nil
        self.sink = nil
        isRecording = false
        level = 0
        setRecoveryStatus("")
        lastFinishedURL = url
        return url
    }

    func cancel() {
        let url = stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        lastFinishedURL = nil
        elapsed = 0
    }

    @objc private func applicationWillTerminate(_ notification: Notification) { _ = stop() }

    deinit {
        recoveryTask?.cancel()
        engine?.stop()
        try? sink?.close()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        NotificationCenter.default.removeObserver(self)
    }
}

@MainActor
final class SpeechTranscriber: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var progress: Double = 0
    /// 识别失败或取消时，不让已经完成的前半段文字消失。
    @Published private(set) var partialSegments: [TranscriptSegment] = []
    @Published private(set) var recognitionStatus = ""
    var onStatusChange: ((String) -> Void)?
    var contextualStrings: [String] = []

    private var runID: UUID?
    private var activeRecognition: FileRecognitionOperation?
    private var activeExport: AudioExportOperation?
    private var activeNativeRecognition: LiveSpeechRecognizer?

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
        setStatus("正在读取录音…")
        defer {
            if runID == id {
                runID = nil
                activeNativeRecognition?.cancel()
                activeNativeRecognition = nil
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
        activeNativeRecognition?.cancel()
        activeRecognition?.cancel()
        activeExport?.cancel()
        activeRecognition = nil
        activeNativeRecognition = nil
        activeExport = nil
        isTranscribing = false
    }

    private func setStatus(_ status: String) {
        guard recognitionStatus != status else { return }
        recognitionStatus = status
        onStatusChange?(status)
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id else { throw CancellationError() }
    }

    private func performTranscription(url: URL, locale: String, allowCloudRecognition: Bool,
                                      contextualStrings: [String], id: UUID) async throws
        -> [TranscriptSegment] {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return try await performNativeTranscription(
                url: url, locale: locale, contextualStrings: contextualStrings, id: id
            )
        }
        #endif
        // 仅旧系统使用 SFSpeechRecognizer 授权；新接口不受 Siri／听写开关限制。
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

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func performNativeTranscription(
        url: URL, locale: String, contextualStrings: [String], id: UUID
    ) async throws -> [TranscriptSegment] {
        // 只记录操作阶段及数值；不记录媒体路径、原文、错误正文或 NSError.userInfo。
        let logger = Logger(subsystem: "app.hearnote.mac", category: "AppleSpeechFileStage")
        let diagnosticRun = id.uuidString
        var diagnosticStage = "decode"
        var diagnosticSucceeded = false
        func enter(_ stage: String) {
            diagnosticStage = stage
            logger.info("run=\(diagnosticRun, privacy: .public) stage=\(stage, privacy: .public) event=enter")
        }
        defer {
            let completed = diagnosticSucceeded ? 1 : 0
            let cancelled = Task.isCancelled ? 1 : 0
            logger.notice("run=\(diagnosticRun, privacy: .public) stage=\(diagnosticStage, privacy: .public) event=end completed=\(completed, privacy: .public) cancelled=\(cancelled, privacy: .public)")
        }
        enter("decode")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearnote-apple-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file: AVAudioFile
        do {
            // 音频文件直接解码为 PCM，避免再次压缩以及按固定秒数切断语句。
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            try checkRun(id)
            enter("extractAudio")
            let asset = AVURLAsset(url: url)
            guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                throw MediaServiceError.noAudio
            }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw MediaServiceError.invalidDuration }
            try checkRun(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audioURL = directory.appendingPathComponent("audio.m4a")
            guard let exporter = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetAppleM4A
            ) else { throw MediaServiceError.exportFailed("此文件无法读取为识别用音频。") }
            exporter.outputURL = audioURL
            exporter.outputFileType = .m4a
            let operation = AudioExportOperation(
                session: exporter, timeoutSeconds: max(180, min(3600, duration)),
                action: "提取完整音轨"
            )
            activeExport = operation
            setStatus("正在提取视频音轨，原文件保留…")
            try await operation.run()
            activeExport = nil
            try checkRun(id)
            enter("decodeExtracted")
            file = try AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        try checkRun(id)
        guard file.length > 0, file.processingFormat.sampleRate > 0 else {
            throw MediaServiceError.invalidDuration
        }
        let processingFormat = file.processingFormat
        logger.info("run=\(diagnosticRun, privacy: .public) stage=decoded frames=\(file.length, privacy: .public) rate=\(processingFormat.sampleRate, privacy: .public) channels=\(processingFormat.channelCount, privacy: .public) pcm=\(processingFormat.commonFormat.rawValue, privacy: .public)")
        let native = LiveSpeechRecognizer()
        var fileContext: AppleSpeechFileContext?
        activeNativeRecognition = native
        native.onStatusChange = { [weak self] status in
            guard let self, self.runID == id else { return }
            self.setStatus(status)
        }
        enter("modelPreparation")
        try await native.start(
            locale: locale, allowCloudRecognition: false, contextualStrings: contextualStrings,
            source: "录音", onUpdate: { [weak self] segment, _ in
                guard let self, self.runID == id else { return }
                let mapped: TranscriptSegment
                if let fileContext {
                    guard let projected = fileContext.project(segment) else { return }
                    mapped = projected
                } else {
                    mapped = segment
                }
                if mapped.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.partialSegments.removeAll { $0.id == mapped.id }
                } else if let index = self.partialSegments.firstIndex(where: { $0.id == mapped.id }) {
                    self.partialSegments[index] = mapped
                } else {
                    self.partialSegments.append(mapped)
                }
                self.partialSegments.sort { $0.start < $1.start }
            }
        )
        try checkRun(id)
        enter("modelReady")
        if native.usesSpeechAnalyzer {
            guard let context = AppleSpeechFileContext(
                duration: Double(file.length) / file.processingFormat.sampleRate,
                sampleRate: file.processingFormat.sampleRate
            ) else { throw MediaServiceError.invalidDuration }
            fileContext = context
            native.configureFileDiagnostics(
                prefixDuration: context.prefixDuration, originalDuration: context.originalDuration,
                operationID: id
            )
            setStatus("正在转写音频，原文件保留…")
            enter("prefixInput")
            var prefixFrame: Int64 = 0
            while let chunk = context.prefixChunk(at: prefixFrame) {
                try checkRun(id)
                guard let silence = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk.frameCount)
                ) else {
                    throw MediaServiceError.recognitionFailed("无法分配识别音频缓冲区。")
                }
                silence.frameLength = AVAudioFrameCount(chunk.frameCount)
                let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
                for index in buffers.indices {
                    guard let data = buffers[index].mData, buffers[index].mDataByteSize > 0 else {
                        throw MediaServiceError.recognitionFailed("无法初始化识别音频缓冲区。")
                    }
                    memset(data, 0, Int(buffers[index].mDataByteSize))
                }
                try await native.appendForTranscription(silence, at: chunk.start)
                try checkRun(id)
                prefixFrame += Int64(chunk.frameCount)
            }
        }
        // 小块输入按 analyzer 消费速度等待，内存不随录音时长增长。
        enter("fileInput")
        var diagnosticInputs = 0
        while file.framePosition < file.length {
            try checkRun(id)
            let offset = Double(file.framePosition) / file.processingFormat.sampleRate
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else {
                throw MediaServiceError.recognitionFailed("无法分配识别音频缓冲区。")
            }
            diagnosticInputs += 1
            let reportsInput = diagnosticInputs <= 8 || diagnosticInputs % 256 == 0
                || file.length - file.framePosition <= 8192
            if reportsInput {
                logger.info("run=\(diagnosticRun, privacy: .public) stage=fileInput event=readBegin sequence=\(diagnosticInputs, privacy: .public) framePosition=\(file.framePosition, privacy: .public)")
            }
            try file.read(into: buffer, frameCount: 8192)
            if reportsInput {
                logger.info("run=\(diagnosticRun, privacy: .public) stage=fileInput event=readEnd sequence=\(diagnosticInputs, privacy: .public) frames=\(buffer.frameLength, privacy: .public) framePosition=\(file.framePosition, privacy: .public)")
            }
            guard buffer.frameLength > 0 else { break }
            let inputOffset: Double
            if let fileContext {
                guard let shifted = fileContext.inputOffset(forOriginalOffset: offset) else {
                    throw MediaServiceError.invalidDuration
                }
                inputOffset = shifted
            } else {
                inputOffset = offset
            }
            try await native.appendForTranscription(buffer, at: inputOffset)
            try checkRun(id)
            let fedProgress = min(0.99, Double(file.framePosition) / Double(file.length))
            if Int(fedProgress * 100) != Int(progress * 100) {
                progress = fedProgress
                setStatus("\(native.backendDescription)正在转写 \(Int(progress * 100))% · 原文件保留")
            }
            await Task.yield()
        }
        try checkRun(id)
        logger.info("run=\(diagnosticRun, privacy: .public) stage=inputFinished buffers=\(diagnosticInputs, privacy: .public) framePosition=\(file.framePosition, privacy: .public) totalFrames=\(file.length, privacy: .public)")
        setStatus("正在定稿最后一段…")
        enter("finalization")
        await native.finish(timeout: 120)
        try checkRun(id)
        enter("finalizationReturned")
        let finalSegments = partialSegments.count
        let nativeFailed = native.errorMessage == nil ? 0 : 1
        logger.notice("run=\(diagnosticRun, privacy: .public) stage=finalizationReturned segments=\(finalSegments, privacy: .public) nativeFailed=\(nativeFailed, privacy: .public)")
        if let error = native.errorMessage {
            throw MediaServiceError.recognitionFailed(error)
        }
        guard !partialSegments.isEmpty else {
            throw MediaServiceError.recognitionFailed("没有识别到文字。请检查录音和所选语种；已有原文保留。")
        }
        progress = 1
        setStatus("转写完成")
        diagnosticSucceeded = true
        return partialSegments
    }
    #endif
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
    private let timeoutNanoseconds: UInt64
    private let action: String

    init(session: AVAssetExportSession, timeoutSeconds: Double = 90, action: String = "音频分段") {
        self.session = session
        self.action = action
        timeoutNanoseconds = UInt64(max(1, min(3600, timeoutSeconds.isFinite ? timeoutSeconds : 90))
                                   * 1_000_000_000)
    }

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
            let timeout = timeoutNanoseconds
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: timeout) }
                catch { return }
                guard let self, !self.completed else { return }
                self.session.cancelExport()
                self.finish(error: MediaServiceError.timedOut(self.action))
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
