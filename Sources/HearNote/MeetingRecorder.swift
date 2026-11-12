import AVFoundation
import Combine
import CoreMedia
import Foundation

enum RecordingSource: String, CaseIterable, Identifiable {
    case microphone
    case system
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .system: return "系统声音"
        case .both: return "麦克风 + 系统声音"
        }
    }

    var description: String {
        switch self {
        case .microphone:
            return "录制你说话和周围的声音。"
        case .system:
            return "录制 Zoom、飞书等会议，以及其他 App 播放的全部系统声音。"
        case .both:
            return "录制你和会议对方的声音。系统音作为参考尝试消除外放回声，保留自己的发言；耳机可进一步减少串音。"
        }
    }

    var includesMicrophone: Bool { self != .system }
    var includesSystem: Bool { self != .microphone }
}

private enum MeetingRecorderError: LocalizedError {
    case busy
    case microphoneDenied
    case noAudio
    case noAudioRetained(URL)
    case exportFailed(String, URL)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "录音正在开始或保存，请稍后再试。"
        case .microphoneDenied:
            return "麦克风权限未获允许。请在「系统设置 → 隐私与安全性 → 麦克风」允许听译。"
        case .noAudio:
            return "本次没有录制到音频。请检查所选声音来源和系统权限后重试。"
        case .noAudioRetained(let recoveryDirectory):
            return "本次没有可读取的完整音轨，暂时无法生成回放。原始采集文件已保留在 \(recoveryDirectory.path)，可用于恢复或排查。"
        case .exportFailed(let detail, let recoveryDirectory):
            return "会议录音合成失败：\(detail)。原始录音已保留在 \(recoveryDirectory.path)，可用于恢复。"
        }
    }
}

/// One meeting owns one pair of recorders. Permission dialogs finish before
/// either source starts. Both clocks are normalized to the host clock.
@MainActor
final class MeetingRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0
    @Published private(set) var source: RecordingSource = .microphone
    @Published private(set) var errorMessage: String?
    @Published private(set) var microphoneAudioDuration: Double = 0
    @Published private(set) var systemAudioDuration: Double = 0
    @Published private(set) var microphoneAudioLevel: Double = 0
    @Published private(set) var systemAudioLevel: Double = 0
    @Published private(set) var echoStatus = ""
    /// The latest saved session's originals. Starting a new session clears this
    /// shortcut, while earlier sessions remain in Recording/Originals.
    @Published private(set) var originalTracksDirectory: URL?

    /// These offsets share the timeline used by the final mixed audio file.
    /// Read the corresponding offset inside the first onBuffer callback.
    @Published private(set) var firstMicrophoneOffset: TimeInterval = 0
    @Published private(set) var firstSystemOffset: TimeInterval = 0
    private(set) var currentMicrophoneOffset: TimeInterval = 0
    private(set) var currentSystemOffset: TimeInterval = 0

    var onMicrophoneBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onSystemBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private enum Phase { case idle, starting, recording, stopping }
    private var phase: Phase = .idle
    private var generation = UUID()
    private var microphone: AudioRecorder?
    private var systemCapture: SystemAudioCapture?
    private var echoProcessor: MeetingEchoProcessor?
    private var sessionDirectory: URL?
    private var outputDirectory: URL?
    private var startedHostTime: TimeInterval = 0
    private var startedAt = Date()
    private var systemLevel: Double = 0
    private var receivedSystemBuffer = false
    private var capturedMicrophoneDuration: Double = 0
    private var capturedSystemDuration: Double = 0
    private var lastMicrophoneBufferAt = -Double.infinity
    private var lastSystemBufferAt = -Double.infinity
    private var timerTask: Task<Void, Never>?
    private var activeExport: AVAssetExportSession?

    func start(in directory: URL, source requestedSource: RecordingSource) async throws {
        guard phase == .idle else { throw MeetingRecorderError.busy }
        phase = .starting
        let sessionID = UUID()
        generation = sessionID
        source = requestedSource
        errorMessage = nil
        echoStatus = ""
        originalTracksDirectory = nil
        elapsed = 0
        level = 0
        systemLevel = 0
        receivedSystemBuffer = false
        capturedMicrophoneDuration = 0
        capturedSystemDuration = 0
        microphoneAudioDuration = 0
        systemAudioDuration = 0
        microphoneAudioLevel = 0
        systemAudioLevel = 0
        lastMicrophoneBufferAt = -Double.infinity
        lastSystemBufferAt = -Double.infinity
        firstMicrophoneOffset = 0
        firstSystemOffset = 0
        currentMicrophoneOffset = 0
        currentSystemOffset = 0
        let temporary = directory.appendingPathComponent(
            ".meeting-\(sessionID.uuidString)", isDirectory: true
        )
        let mic = requestedSource.includesMicrophone ? AudioRecorder() : nil
        let system = requestedSource.includesSystem ? SystemAudioCapture() : nil
        microphone = mic
        systemCapture = system
        sessionDirectory = temporary
        outputDirectory = directory
        var sessionEcho: MeetingEchoProcessor?

        do {
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true
            )
            // Retrieving shareable content invokes macOS system-recording
            // permission when needed; it does not require a meeting screen share.
            if let system { try await system.prepare() }
            try ensureCurrent(sessionID)
            if mic != nil { try await Self.authorizeMicrophone() }
            try ensureCurrent(sessionID)
            startedHostTime = Self.hostTime()
            startedAt = Date()
            let epoch = startedHostTime
            if requestedSource == .both {
                do {
                    let processor = try MeetingEchoProcessor(
                        directory: temporary, epoch: epoch,
                        onOutput: { [weak self] pcm, hostTime in
                            guard let self, self.generation == sessionID, self.phase != .idle else { return }
                            self.currentMicrophoneOffset = max(0, hostTime - epoch)
                            self.onMicrophoneBuffer?(pcm)
                        },
                        onStatus: { [weak self] status in
                            guard let self, self.generation == sessionID, self.phase != .idle else { return }
                            self.echoStatus = status
                        }
                    )
                    sessionEcho = processor
                    echoProcessor = processor
                    mic?.onCapturedBuffer = { [processor] pcm, hostTime in
                        processor.appendMicrophone(pcm, hostTime: hostTime)
                    }
                    system?.onCapturedBuffer = { [processor] pcm, hostTime in
                        processor.appendReference(pcm, hostTime: hostTime)
                    }
                    echoStatus = "回声处理正在等待系统参考，麦克风原音保留"
                } catch {
                    echoStatus = "外放回声消除不可用：\(error.localizedDescription)。使用麦克风原音。"
                }
            }

            mic?.onBuffer = { [weak self, weak mic] pcm in
                guard let self, self.generation == sessionID,
                      self.phase != .idle else {
                    return
                }
                if let firstHostTime = mic?.firstBufferHostTime {
                    self.firstMicrophoneOffset = max(0, firstHostTime - epoch)
                }
                let bufferDuration = Self.duration(of: pcm)
                self.capturedMicrophoneDuration += bufferDuration
                self.lastMicrophoneBufferAt = Self.hostTime()
                if self.echoProcessor == nil {
                    self.currentMicrophoneOffset = self.firstMicrophoneOffset
                        + max(0, (mic?.elapsed ?? 0) - bufferDuration)
                    self.onMicrophoneBuffer?(pcm)
                }
            }
            mic?.onError = { [weak self] error in
                self?.recordFailure(error, for: sessionID)
            }
            system?.onBuffer = { [weak self] pcm, hostTime in
                guard let self, self.generation == sessionID,
                      self.phase != .idle else {
                    return
                }
                // This callback precedes the app's live transcriber append.
                if !self.receivedSystemBuffer {
                    self.firstSystemOffset = max(0, hostTime - epoch)
                    self.receivedSystemBuffer = true
                }
                self.currentSystemOffset = max(0, hostTime - epoch)
                self.capturedSystemDuration += Self.duration(of: pcm)
                self.lastSystemBufferAt = Self.hostTime()
                self.onSystemBuffer?(pcm)
            }
            system?.onLevel = { [weak self] value in
                guard let self, self.generation == sessionID else { return }
                self.systemLevel = value
            }
            system?.onError = { [weak self] error in
                self?.recordFailure(error, for: sessionID)
            }

            if let system { try await system.start(in: temporary) }
            try ensureCurrent(sessionID)
            if let mic { try await mic.start(in: temporary) }
            try ensureCurrent(sessionID)
            phase = .recording
            isRecording = true
            beginTimer(sessionID)
        } catch {
            mic?.cancel()
            if let system { await system.cancel() }
            await sessionEcho?.cancel()
            try? FileManager.default.removeItem(at: temporary)
            if generation == sessionID {
                microphone = nil
                systemCapture = nil
                echoProcessor = nil
                sessionDirectory = nil
                outputDirectory = nil
                phase = .idle
                isRecording = false
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
            throw error
        }
    }

    func stop() async throws -> URL? {
        if phase == .idle { return nil }
        guard phase == .recording else { throw MeetingRecorderError.busy }
        phase = .stopping
        isRecording = false
        timerTask?.cancel()
        timerTask = nil
        let sessionID = generation
        let epoch = startedHostTime
        let mic = microphone
        let system = systemCapture
        let echo = echoProcessor
        let temporary = sessionDirectory
        let destination = outputDirectory
        let microphoneURL = mic?.stop()
        let microphoneHostTime = mic?.firstBufferHostTime
        let systemRecording = await system?.stop()
        let echoRecording = await echo?.finish()
        guard generation == sessionID else { throw CancellationError() }

        var sources: [(url: URL, offset: TimeInterval)] = []
        if let echoURL = echoRecording?.url, let echoHostTime = echoRecording?.firstHostTime,
           let file = try? AVAudioFile(forReading: echoURL), file.length > 0 {
            sources.append((echoURL, max(0, echoHostTime - epoch)))
        } else if let microphoneURL, let microphoneHostTime,
           let file = try? AVAudioFile(forReading: microphoneURL),
           file.length > 0 {
            sources.append(
                (microphoneURL, max(0, microphoneHostTime - epoch))
            )
        }
        if let systemRecording, systemRecording.hasAudio,
           let systemHostTime = systemRecording.firstHostTime {
            sources.append(
                (systemRecording.url, max(0, systemHostTime - epoch))
            )
        }
        if source == .both, sources.count == 1 {
            errorMessage = sources[0].url == microphoneURL || sources[0].url == echoRecording?.url
                ? "系统声音没有成功录制，本次仅保存了麦克风录音。"
                : "麦克风没有成功录制，本次仅保存了系统声音。"
        }
        if let failure = systemRecording?.failure {
            recordFailure(failure, for: sessionID)
        }
        if errorMessage == nil, let warning = systemRecording?.cleanupWarning {
            errorMessage = warning
        }
        if let warning = echoRecording?.failure {
            echoStatus = warning
            if errorMessage == nil { errorMessage = warning }
        }
        guard !sources.isEmpty, let temporary, let destination else {
            clearSession(sessionID)
            if let temporary {
                // An unreadable/partial CAF may still contain recoverable
                // capture data. Only explicit user cancellation deletes it.
                originalTracksDirectory = temporary
                let recovery = MeetingRecorderError.noAudioRetained(temporary)
                errorMessage = recovery.localizedDescription
                throw recovery
            }
            throw MeetingRecorderError.noAudio
        }
        let output = destination.appendingPathComponent(
            "meeting-\(sessionID.uuidString).m4a"
        )
        do {
            try await mix(
                sources: sources, to: output, sessionID: sessionID
            )
            guard generation == sessionID else { throw CancellationError() }
            var tracks: [OriginalMeetingAudioArchive.Track] = []
            if let microphoneURL {
                tracks.append(.init(
                    role: .microphone, url: microphoneURL,
                    firstOffsetSeconds: microphoneHostTime.map { max(0, $0 - epoch) }
                ))
            }
            if let systemRecording {
                tracks.append(.init(
                    role: .system, url: systemRecording.url,
                    firstOffsetSeconds: systemRecording.firstHostTime.map { max(0, $0 - epoch) }
                ))
            }
            if let cleanedURL = echoRecording?.url {
                tracks.append(.init(
                    role: .cleanedMicrophone, url: cleanedURL,
                    firstOffsetSeconds: echoRecording?.firstHostTime.map { max(0, $0 - epoch) }
                ))
            }
            let metadata = OriginalMeetingAudioArchive.Metadata(
                capturedAt: startedAt, recordingSource: source.rawValue,
                tracks: tracks, echo: echoRecording?.diagnostics
            )
            do {
                originalTracksDirectory = try OriginalMeetingAudioArchive.preserve(
                    sessionDirectory: temporary, in: destination, sessionID: sessionID,
                    microphoneURL: microphoneURL, metadata: metadata
                )
            } catch {
                // Mixing succeeded. Keep its output and every original in the
                // temporary folder if archiving fails; never delete that folder.
                originalTracksDirectory = temporary
                let warning = "录音已保存；原音归档未完成，原始录音仍保留在 \(temporary.path)。"
                errorMessage = errorMessage.map { "\($0)\n\(warning)" } ?? warning
            }
            clearSession(sessionID)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            clearSession(sessionID)
            if error is CancellationError {
                try? FileManager.default.removeItem(at: temporary)
                throw CancellationError()
            }
            // Do not discard original audio when export or storage fails.
            originalTracksDirectory = temporary
            let recovery = MeetingRecorderError.exportFailed(
                error.localizedDescription, temporary
            )
            errorMessage = recovery.localizedDescription
            throw recovery
        }
    }

    func cancel() async {
        let oldGeneration = generation
        generation = UUID() // Ignore callbacks and suspended startup work.
        phase = .stopping
        isRecording = false
        timerTask?.cancel()
        timerTask = nil
        activeExport?.cancelExport()
        activeExport = nil
        microphone?.cancel()
        let system = systemCapture
        let echo = echoProcessor
        let temporary = sessionDirectory
        microphone = nil
        systemCapture = nil
        echoProcessor = nil
        sessionDirectory = nil
        outputDirectory = nil
        if let system { await system.cancel() }
        if let echo { await echo.cancel() }
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        if generation != oldGeneration {
            phase = .idle
            level = 0
            systemLevel = 0
            elapsed = 0
        }
    }

    private func mix(
        sources: [(url: URL, offset: TimeInterval)],
        to output: URL,
        sessionID: UUID
    ) async throws {
        let composition = AVMutableComposition()
        var parameters: [AVAudioMixInputParameters] = []
        for source in sources {
            try ensureCurrent(sessionID)
            let asset = AVURLAsset(url: source.url)
            guard let assetTrack = try await asset.loadTracks(
                withMediaType: .audio
            ).first else { throw MeetingRecorderError.noAudio }
            let range = try await assetTrack.load(.timeRange)
            guard CMTimeGetSeconds(range.duration) > 0,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { throw MeetingRecorderError.noAudio }
            let offset = CMTime(seconds: source.offset, preferredTimescale: 48_000)
            try compositionTrack.insertTimeRange(
                range, of: assetTrack, at: offset
            )
            let inputParameters = AVMutableAudioMixInputParameters(
                track: compositionTrack
            )
            // Both-source meetings replace the microphone with its processed track
            // when available; equal gains additionally reduce mixing clipping.
            inputParameters.setVolume(
                sources.count > 1 ? 0.65 : 1, at: .zero
            )
            parameters.append(inputParameters)
        }
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A
        ) else { throw MeetingRecorderError.noAudio }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = parameters
        exporter.audioMix = audioMix
        exporter.outputURL = output
        exporter.outputFileType = .m4a
        activeExport = exporter
        defer {
            if generation == sessionID { activeExport = nil }
        }
        await withTaskCancellationHandler {
            await exporter.export()
        } onCancel: {
            exporter.cancelExport()
        }
        try ensureCurrent(sessionID)
        guard exporter.status == .completed else {
            if exporter.status == .cancelled { throw CancellationError() }
            throw exporter.error ?? MeetingRecorderError.noAudio
        }
    }

    private func ensureCurrent(_ sessionID: UUID) throws {
        try Task.checkCancellation()
        guard generation == sessionID else { throw CancellationError() }
    }

    private func beginTimer(_ sessionID: UUID) {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == sessionID,
                      self.phase == .recording else { return }
                let now = Self.hostTime()
                self.elapsed = max(0, now - self.startedHostTime)
                self.microphoneAudioDuration = self.capturedMicrophoneDuration
                self.systemAudioDuration = self.capturedSystemDuration
                self.microphoneAudioLevel = now - self.lastMicrophoneBufferAt < 1
                    ? (self.microphone?.level ?? 0) : 0
                self.systemAudioLevel = now - self.lastSystemBufferAt < 1 ? self.systemLevel : 0
                self.level = max(self.microphoneAudioLevel, self.systemAudioLevel)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func recordFailure(_ error: Error, for sessionID: UUID) {
        guard generation == sessionID else { return }
        errorMessage = error.localizedDescription
        onError?(error)
    }

    private func clearSession(_ sessionID: UUID) {
        guard generation == sessionID else { return }
        microphone?.onBuffer = nil
        microphone?.onCapturedBuffer = nil
        microphone?.onError = nil
        microphone = nil
        systemCapture = nil
        echoProcessor = nil
        sessionDirectory = nil
        outputDirectory = nil
        activeExport = nil
        phase = .idle
        isRecording = false
        level = 0
        systemLevel = 0
        microphoneAudioLevel = 0
        systemAudioLevel = 0
    }

    private static func authorizeMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MeetingRecorderError.microphoneDenied
            }
        default:
            throw MeetingRecorderError.microphoneDenied
        }
    }

    private static func hostTime() -> TimeInterval {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private static func duration(of buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.format.sampleRate.isFinite, buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameLength) / buffer.format.sampleRate
    }
}
