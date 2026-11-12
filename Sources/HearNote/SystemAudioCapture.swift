import AVFoundation
import CoreMedia
import Foundation
import HearNoteCore
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
    case permission(String)
    case noDisplay
    case noAudio
    case invalidBuffer
    case changedFormat
    case writeFailed(String)
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .permission(let detail):
            return "无法获取系统声音录制权限。请在「系统设置 → 隐私与安全性 → 屏幕录制」允许听译，必要时退出并重新打开 App。\(detail)"
        case .noDisplay:
            return "没有可用于获取系统声音的显示器。请连接显示器后重试。"
        case .noAudio:
            return "本次没有获取到系统音频。请确认会议已播放声音，并检查系统录制权限。"
        case .invalidBuffer:
            return "系统声音的数据格式无法读取，录音已停止。"
        case .changedFormat:
            return "系统声音格式在录制期间发生变化。请重新开始录音。"
        case .writeFailed(let detail):
            return "系统声音保存失败：\(detail)"
        case .streamFailed(let detail):
            return "系统声音录制中断：\(detail)"
        }
    }
}

struct SystemAudioRecording {
    let url: URL
    let firstHostTime: TimeInterval?
    let frameCount: Int64
    let sampleRate: Double
    let failure: Error?
    let cleanupWarning: String?

    var hasAudio: Bool { frameCount > 0 && sampleRate > 0 }
}

/// ScreenCaptureKit handles permission and system audio routing. Only `.audio`
/// output is attached: screen pixels are neither delivered nor saved.
@MainActor
final class SystemAudioCapture {
    var onBuffer: ((AVAudioPCMBuffer, TimeInterval) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onError: ((Error) -> Void)?

    private var filter: SCContentFilter?
    private var captureStream: SCStream?
    private var sink: SystemAudioSink?
    private var outputURL: URL?
    private var startTask: Task<Void, Error>?
    private var stopOperation = AudioCaptureStopOperation<SystemAudioRecording?>()
    private var generation = UUID()
    private var starting = false
    private var stopping = false

    /// Ask for system recording permission before either audio source starts.
    func prepare() async throws {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            try Task.checkCancellation()
            guard let display = content.displays.first else {
                throw SystemAudioCaptureError.noDisplay
            }
            filter = SCContentFilter(
                display: display, excludingApplications: [], exceptingWindows: []
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SystemAudioCaptureError {
            throw error
        } catch {
            throw SystemAudioCaptureError.permission(error.localizedDescription)
        }
    }

    func start(in directory: URL) async throws {
        guard !starting, !stopping else { throw CancellationError() }
        guard captureStream == nil, startTask == nil else { return }
        starting = true
        defer { starting = false }
        let sessionID = generation
        if filter == nil { try await prepare() }
        try Task.checkCancellation()
        guard generation == sessionID else { throw CancellationError() }
        guard let filter else { throw SystemAudioCaptureError.noDisplay }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("system.caf")

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        // Audio only. These keep the required display stream inexpensive.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let bufferCallback = onBuffer
        let levelCallback = onLevel
        let errorCallback = onError
        let writer = SystemAudioSink(
            url: url,
            onBuffer: bufferCallback,
            onLevel: levelCallback,
            onError: errorCallback
        )
        let stream = SCStream(
            filter: filter, configuration: configuration, delegate: writer
        )
        try stream.addStreamOutput(
            writer, type: .audio, sampleHandlerQueue: writer.queue
        )
        sink = writer
        captureStream = stream
        outputURL = url
        stopOperation = AudioCaptureStopOperation()
        let startup = Task { try await stream.startCapture() }
        startTask = startup
        do {
            try await startup.value
            try Task.checkCancellation()
            guard generation == sessionID, captureStream === stream,
                  !stopping else { throw CancellationError() }
            startTask = nil
        } catch {
            // stop/cancel may have entered while startCapture was suspended.
            // They and this cleanup must await the same stop/flush.
            _ = await stop()
            if outputURL == url { outputURL = nil }
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError { throw CancellationError() }
            throw SystemAudioCaptureError.streamFailed(error.localizedDescription)
        }
    }

    func stop() async -> SystemAudioRecording? {
        generation = UUID()
        let operation = stopOperation
        return await operation.run { [self] in
            guard let stream = captureStream, let writer = sink else { return nil }
            let endHostTime = CMTimeGetSeconds(
                CMClockGetTime(CMClockGetHostTimeClock())
            )
            stopping = true
            writer.beginStopping(at: endHostTime)
            captureStream = nil
            sink = nil
            let startup = startTask
            startTask = nil
            // Avoid asking ScreenCaptureKit to start and stop the same stream
            // concurrently if cancellation arrives during startup.
            if let startup { _ = try? await startup.value }
            do {
                try await stream.stopCapture()
            } catch {
                writer.markStreamFailure(error)
            }
            let result = await writer.finish(endingAt: endHostTime)
            stopping = false
            return result
        }
    }

    func cancel() async {
        let url = outputURL
        _ = await stop()
        if outputURL == url { outputURL = nil }
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

/// The file and all timing state belong to one serial queue. Delegate callbacks
/// never touch SwiftUI state directly. Each forwarded PCM buffer owns its memory.
private final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(
        label: "app.hearnote.system-audio", qos: .userInitiated
    )

    private let url: URL
    private let onBuffer: ((AVAudioPCMBuffer, TimeInterval) -> Void)?
    private let onLevel: ((Double) -> Void)?
    private let onError: ((Error) -> Void)?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var firstHostTime: TimeInterval?
    private var writtenFrames: Int64 = 0
    private var failure: Error?
    private var finished = false
    private var cleanupWarning: String?
    private let lifecycleLock = NSLock()
    private var lifecycle = AudioCaptureLifecycle()

    init(
        url: URL,
        onBuffer: ((AVAudioPCMBuffer, TimeInterval) -> Void)?,
        onLevel: ((Double) -> Void)?,
        onError: ((Error) -> Void)?
    ) {
        self.url = url
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onError = onError
        super.init()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, !finished, failure == nil,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            let pcm = try copyPCM(sampleBuffer)
            guard pcm.frameLength > 0 else { return }
            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let converted: CMTime
            if let clock = stream.synchronizationClock {
                converted = CMSyncConvertTime(
                    samplePTS, from: clock, to: CMClockGetHostTimeClock()
                )
            } else {
                converted = samplePTS
            }
            let hostTime = CMTimeGetSeconds(converted)
            guard hostTime.isFinite else {
                throw SystemAudioCaptureError.invalidBuffer
            }
            lifecycleLock.lock()
            let acceptedFrames = lifecycle.acceptedFrameCount(
                start: hostTime, sampleRate: pcm.format.sampleRate, frames: Int(pcm.frameLength)
            )
            lifecycleLock.unlock()
            guard acceptedFrames > 0 else { return }
            pcm.frameLength = AVAudioFrameCount(acceptedFrames)
            if file == nil {
                format = pcm.format
                file = try AVAudioFile(
                    forWriting: url,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
                firstHostTime = hostTime
            }
            guard let file, let format, let firstHostTime else {
                throw SystemAudioCaptureError.invalidBuffer
            }
            guard format.isEqual(pcm.format) else {
                throw SystemAudioCaptureError.changedFormat
            }

            // A system stream may pause delivery while no app produces audio.
            // Preserve those gaps rather than compressing the meeting timeline.
            let expectedTime = firstHostTime
                + Double(writtenFrames) / format.sampleRate
            let missingSeconds = hostTime - expectedTime
            if missingSeconds > 0.02 {
                let missingFrames = Int64(
                    (missingSeconds * format.sampleRate).rounded()
                )
                try appendSilence(
                    frameCount: missingFrames, format: format, file: file
                )
            } else if missingSeconds < -0.25 {
                // A backward clock jump must not silently damage synchronization.
                throw SystemAudioCaptureError.invalidBuffer
            }
            try file.write(from: pcm)
            writtenFrames += Int64(pcm.frameLength)
            let energy = Self.level(of: pcm)
            let bufferCallback = onBuffer
            let levelCallback = onLevel
            Task { @MainActor in
                bufferCallback?(pcm, hostTime)
                levelCallback?(energy)
            }
        } catch {
            setFailure(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        markStreamFailure(error)
    }

    func beginStopping(at hostTime: TimeInterval) {
        lifecycleLock.lock()
        lifecycle.beginStopping(at: hostTime)
        lifecycleLock.unlock()
    }

    func markStreamFailure(_ error: Error) {
        // Classify at callback arrival, before its queued processing. A real
        // interruption just before Stop remains a recording failure.
        lifecycleLock.lock()
        let disposition = lifecycle.streamErrorDisposition
        lifecycleLock.unlock()
        queue.async { [self] in
            guard !finished else { return }
            switch disposition {
            case .recordingFailure:
                setFailure(SystemAudioCaptureError.streamFailed(error.localizedDescription))
            case .shutdownWarning:
                if cleanupWarning == nil {
                    cleanupWarning = "系统声音收尾报告：\(error.localizedDescription)。已采集的音频仍会保存。"
                }
            case .ignore:
                break
            }
        }
    }

    func finish(endingAt endHostTime: TimeInterval? = nil) async -> SystemAudioRecording {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !finished, failure == nil,
                   let endHostTime, let firstHostTime, let file, let format {
                    let expectedTime = firstHostTime
                        + Double(writtenFrames) / format.sampleRate
                    let trailingSeconds = endHostTime - expectedTime
                    if trailingSeconds > 0.02 {
                        do {
                            try appendSilence(
                                frameCount: Int64(
                                    (trailingSeconds * format.sampleRate).rounded()
                                ),
                                format: format,
                                file: file
                            )
                        } catch {
                            setFailure(
                                SystemAudioCaptureError.writeFailed(
                                    error.localizedDescription
                                )
                            )
                        }
                    }
                }
                finished = true
                file = nil // Flush/close before a composition reads the file.
                lifecycleLock.lock()
                lifecycle.finish()
                lifecycleLock.unlock()
                continuation.resume(
                    returning: SystemAudioRecording(
                        url: url,
                        firstHostTime: firstHostTime,
                        frameCount: writtenFrames,
                        sampleRate: format?.sampleRate ?? 0,
                        failure: failure,
                        cleanupWarning: cleanupWarning
                    )
                )
            }
        }
    }

    private func setFailure(_ error: Error) {
        guard failure == nil, !finished else { return }
        failure = error
        let callback = onError
        Task { @MainActor in callback?(error) }
    }

    private func copyPCM(_ sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw SystemAudioCaptureError.invalidBuffer
        }
        let audioFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard sampleCount > 0, sampleCount <= Int(Int32.max),
              let pcm = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(sampleCount)
              ) else {
            throw SystemAudioCaptureError.invalidBuffer
        }
        pcm.frameLength = AVAudioFrameCount(sampleCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: pcm.mutableAudioBufferList
        )
        guard status == noErr else {
            throw SystemAudioCaptureError.invalidBuffer
        }
        return pcm
    }

    private func appendSilence(
        frameCount: Int64, format: AVAudioFormat, file: AVAudioFile
    ) throws {
        guard frameCount > 0 else { return }
        let chunkCapacity: AVAudioFrameCount = 8_192
        guard let silence = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: chunkCapacity
        ) else { throw SystemAudioCaptureError.invalidBuffer }
        var remaining = frameCount
        while remaining > 0 {
            let count = AVAudioFrameCount(min(Int64(chunkCapacity), remaining))
            silence.frameLength = count
            for audioBuffer in UnsafeMutableAudioBufferListPointer(
                silence.mutableAudioBufferList
            ) {
                if let data = audioBuffer.mData {
                    memset(data, 0, Int(audioBuffer.mDataByteSize))
                }
            }
            try file.write(from: silence)
            writtenFrames += Int64(count)
            remaining -= Int64(count)
        }
    }

    private static func level(of pcm: AVAudioPCMBuffer) -> Double {
        guard pcm.frameLength > 0 else { return 0 }
        var sum: Double = 0
        var count = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(
            pcm.mutableAudioBufferList
        ) {
            guard let data = audioBuffer.mData else { continue }
            if pcm.format.commonFormat == .pcmFormatFloat32 {
                let samples = data.assumingMemoryBound(to: Float.self)
                let size = Int(audioBuffer.mDataByteSize)
                    / MemoryLayout<Float>.stride
                for index in 0..<size {
                    let value = Double(samples[index])
                    sum += value * value
                }
                count += size
            } else if pcm.format.commonFormat == .pcmFormatInt16 {
                let samples = data.assumingMemoryBound(to: Int16.self)
                let size = Int(audioBuffer.mDataByteSize)
                    / MemoryLayout<Int16>.stride
                for index in 0..<size {
                    let value = Double(samples[index]) / 32_768
                    sum += value * value
                }
                count += size
            }
        }
        guard count > 0 else { return 0 }
        return min(1, sqrt(sum / Double(count)) * 6)
    }
}
