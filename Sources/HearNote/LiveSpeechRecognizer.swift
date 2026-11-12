import AVFoundation
import Combine
import Foundation
import HearNoteCore
import Speech

/// 每个输入源使用独立实例。按约5秒短句更新稳定segment，避免整段45秒才能翻译。
@MainActor
final class LiveSpeechRecognizer: ObservableObject {
    @Published private(set) var isRecognizing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var recognitionStatus = "已停止"

    /// 双输入源由调用方设置同一会议起点，保证时间戳在同一条时间轴上。
    var timelineOrigin: Date?
    var onError: ((Error) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var configuration: Configuration?
    private var sessionID: UUID?
    private var streams: [UUID: RecognitionStream] = [:]
    private var currentStreamID: UUID?
    private var origin = Date()
    private var rotationTask: Task<Void, Never>?
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var update: ((TranscriptSegment, Bool) -> Void)?

    private struct Configuration {
        let requiresOnDevice: Bool
        let contextualStrings: [String]
        let source: String
    }

    func start(locale: String, allowCloudRecognition: Bool,
               contextualStrings: [String], source: String,
               onUpdate: @escaping (TranscriptSegment, Bool) -> Void) async throws {
        cancel()
        let id = UUID()
        sessionID = id
        errorMessage = nil
        recognitionStatus = "正在检查语音识别…"
        do {
            let resolvedRecognizer = try await SpeechPermissions.recognizer(
                locale: locale, allowCloudRecognition: allowCloudRecognition
            )
            try Task.checkCancellation()
            guard sessionID == id else { throw CancellationError() }
            recognizer = resolvedRecognizer
            configuration = Configuration(
                requiresOnDevice: !allowCloudRecognition,
                contextualStrings: Array(contextualStrings.prefix(100)),
                source: source
            )
            origin = timelineOrigin ?? Date()
            update = onUpdate
            isRecognizing = true
            recognitionStatus = "等待音频"
            // 捕获权限尚未完成时可能还没有 PCM；先不创建无输入的 Speech request。
        } catch {
            if sessionID == id {
                sessionID = nil
                isRecognizing = false
                recognitionStatus = error is CancellationError ? "已停止" : "识别未就绪"
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            throw error
        }
    }

    /// buffer 必须是独立副本；不能将 AudioEngine tap 会复用的原 buffer 留在异步队列。
    func append(_ buffer: AVAudioPCMBuffer, at timelineOffset: Double? = nil) {
        guard isRecognizing, let sessionID,
              buffer.frameLength > 0, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0 else { return }
        if currentStreamID == nil { openStream(session: sessionID) }
        guard let id = currentStreamID, var stream = streams[id], !stream.ended else { return }
        let incomingDuration = Double(buffer.frameLength) / buffer.format.sampleRate
        let explicitOffset = timelineOffset.flatMap { $0.isFinite ? max(0, $0) : nil }
        if stream.receivedAudio {
            let gap = explicitOffset.map { max(0, $0 - stream.offset - stream.audioDuration) } ?? 0
            // 长静音另开request；当前request不注入整场会议的历史静音。
            if gap > 6 || stream.audioDuration + gap + incomingDuration > 43 {
                rotateStream(session: sessionID)
                // 当前确实有新的 PCM，结束旧 request 后再创建下一 request。
                openStream(session: sessionID)
                guard let newID = currentStreamID, let newStream = streams[newID] else { return }
                stream = newStream
            } else if gap > 0.08 {
                appendSilence(seconds: gap, format: buffer.format, to: stream)
            }
        }
        if !stream.receivedAudio {
            stream.offset = explicitOffset ?? max(0, Date().timeIntervalSince(origin))
            stream.receivedAudio = true
        }
        stream.request.append(buffer)
        stream.audioDuration += incomingDuration
        if recognitionStatus != "识别中" { recognitionStatus = "识别中" }
    }

    private func appendSilence(seconds: Double, format: AVAudioFormat, to stream: RecognitionStream) {
        var remaining = AVAudioFrameCount(seconds * format.sampleRate)
        while remaining > 0 {
            let count = min(remaining, 4096)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
            silence.frameLength = count
            let buffers = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
            for index in buffers.indices {
                if let data = buffers[index].mData {
                    memset(data, 0, Int(buffers[index].mDataByteSize))
                }
            }
            stream.request.append(silence)
            stream.audioDuration += Double(count) / format.sampleRate
            remaining -= count
        }
    }

    /// 停止接收输入，允许 Speech 返回最后一句的最终结果。
    func stop() {
        isRecognizing = false
        rotationTask?.cancel()
        rotationTask = nil
        currentStreamID = nil
        for stream in Array(streams.values) { end(stream) }
        recognitionStatus = streams.isEmpty ? "已停止" : "正在收尾…"
        resolveFinishWaitersIfNeeded()
    }

    /// 保存会议前可 await，此过程最长等待每个最后请求的15秒截止时间。
    func finish() async {
        stop()
        guard !streams.isEmpty else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if streams.isEmpty { continuation.resume() }
                else { finishWaiters.append(continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    /// 明确丢弃本次识别的后续回调，已有文本由外部文档持有。
    func cancel() {
        sessionID = nil
        isRecognizing = false
        rotationTask?.cancel()
        rotationTask = nil
        for stream in streams.values {
            stream.deadline?.cancel()
            stream.request.endAudio()
            stream.task?.cancel()
        }
        streams.removeAll()
        currentStreamID = nil
        recognizer = nil
        configuration = nil
        update = nil
        recognitionStatus = "已停止"
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func openStream(session: UUID) {
        guard let recognizer, let configuration,
              sessionID == session, isRecognizing, currentStreamID == nil else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = configuration.requiresOnDevice
        request.taskHint = .dictation
        request.contextualStrings = configuration.contextualStrings
        request.addsPunctuation = true
        let stream = RecognitionStream(
            request: request, source: configuration.source,
            offset: max(0, Date().timeIntervalSince(origin))
        )
        streams[stream.id] = stream
        currentStreamID = stream.id
        stream.task = recognizer.recognitionTask(with: request) { [weak self, weak stream] result, error in
            Task { @MainActor in
                guard let self, let stream, self.sessionID == session,
                      self.streams[stream.id] != nil else { return }
                if let result {
                    self.receive(result, stream: stream)
                    if result.isFinal && error == nil {
                        let wasCurrent = self.currentStreamID == stream.id
                        self.remove(stream)
                        // 下一 request 等收到下一帧音频再建立，不让静音间隙空跑。
                        if wasCurrent, self.isRecognizing {
                            self.recognitionStatus = "等待音频"
                        }
                        return
                    }
                }
                if let error {
                    self.receive(error, stream: stream, session: session)
                }
            }
        }
        rotationTask?.cancel()
        rotationTask = Task { [weak self, weak stream] in
            do { try await Task.sleep(nanoseconds: 43_000_000_000) }
            catch { return }
            guard let self, let stream, self.sessionID == session,
                  self.isRecognizing, self.currentStreamID == stream.id else { return }
            self.rotateStream(session: session)
        }
    }

    private func rotateStream(session: UUID) {
        guard sessionID == session, let id = currentStreamID,
              let outgoing = streams[id] else { return }
        // 不向两个request重复投喂同一buffer，避免文字重复。
        currentStreamID = nil
        rotationTask?.cancel()
        rotationTask = nil
        end(outgoing)
        if isRecognizing { recognitionStatus = "等待音频" }
    }

    private func end(_ stream: RecognitionStream) {
        guard !stream.ended else { return }
        stream.ended = true
        if !stream.receivedAudio {
            stream.task?.cancel()
            remove(stream)
            return
        }
        stream.request.endAudio()
        stream.deadline = Task { [weak self, weak stream] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            guard let self, let stream, self.streams[stream.id] != nil else { return }
            stream.task?.cancel()
            // 收到了 PCM 却没返回文字，也必须可见；它可能是静音，不能断言录音损坏。
            let warning = LiveSpeechRecognitionError.finalResultTimedOut(
                hasPartialText: !stream.latest.isEmpty
            )
            self.errorMessage = warning.localizedDescription
            self.remove(stream)
            self.onError?(warning)
        }
    }

    private func receive(_ result: SFSpeechRecognitionResult, stream: RecognitionStream) {
        let transcription = result.bestTranscription
        let words = transcription.segments
        guard !words.isEmpty else { return }
        // 固定时间桶不会因为partial的标点变化而重新编号，译文能准确替换同一句。
        let groups = Dictionary(grouping: words.indices) { index in
            Int(max(0, words[index].timestamp) / 5)
        }
        let buckets = groups.keys.sorted()
        let formatted = transcription.formattedString as NSString
        for bucket in buckets {
            guard let indices = groups[bucket],
                  let firstIndex = indices.first, let lastIndex = indices.last else { continue }
            let first = words[firstIndex]
            let last = words[lastIndex]
            let startIndex = first.substringRange.location
            let endIndex = lastIndex + 1 < words.count
                ? words[lastIndex + 1].substringRange.location : formatted.length
            guard startIndex >= 0, endIndex >= startIndex, endIndex <= formatted.length else { continue }
            let text = formatted.substring(with: NSRange(location: startIndex,
                                                        length: endIndex - startIndex))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let segmentID = stream.segmentIDs[bucket] ?? UUID()
            stream.segmentIDs[bucket] = segmentID
            let start = max(0, stream.offset + first.timestamp)
            let segment = TranscriptSegment(
                id: segmentID, start: start,
                end: max(start + 0.1, stream.offset + last.timestamp + last.duration),
                text: text, source: stream.source
            )
            // 前面短句已过时轴边界可用于翻译；Speech仍可更正，沿同UUID替换。
            let finalized = result.isFinal || bucket != buckets.last
            let previous = stream.latest[bucket]
            if previous?.segment != segment || previous?.finalized != finalized {
                stream.latest[bucket] = RecognizedChunk(segment: segment, finalized: finalized)
                update?(segment, finalized)
            }
        }
    }

    private func receive(_ error: Error, stream: RecognitionStream, session: UUID) {
        let wasCurrent = currentStreamID == stream.id
        let hadAudio = stream.receivedAudio
        let endedWithoutWords = stream.ended && stream.latest.isEmpty
        let activeFailure = wasCurrent && !stream.ended && isRecognizing && sessionID == session
        remove(stream)
        // 当前 request 在首帧前失败同样是识别故障，不能让 isRecognizing 假装继续。
        guard activeFailure || (hadAudio && !endedWithoutWords) else { return }
        errorMessage = "实时识别中断：\(error.localizedDescription)。录音仍可继续，之后可以重新转写。"
        // 已结束request的错误不影响正在识别的新一段。
        if activeFailure {
            isRecognizing = false
            recognitionStatus = "识别失败"
            rotationTask?.cancel()
            rotationTask = nil
        }
        onError?(error)
    }

    private func remove(_ stream: RecognitionStream) {
        stream.deadline?.cancel()
        stream.deadline = nil
        stream.task = nil
        streams.removeValue(forKey: stream.id)
        if currentStreamID == stream.id {
            currentStreamID = nil
            rotationTask?.cancel()
            rotationTask = nil
        }
        resolveFinishWaitersIfNeeded()
    }

    private func resolveFinishWaitersIfNeeded() {
        guard streams.isEmpty else { return }
        if !isRecognizing && recognitionStatus == "正在收尾…" { recognitionStatus = "已停止" }
        let waiters = finishWaiters
        finishWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private enum LiveSpeechRecognitionError: LocalizedError {
    case finalResultTimedOut(hasPartialText: Bool)

    var errorDescription: String? {
        switch self {
        case .finalResultTimedOut(let hasPartialText):
            return hasPartialText
                ? "部分语音没有在截止时间内返回最终结果，已保留临时文字与录音，可在会后重新转写。"
                : "已收到音频，但这一段没有在截止时间内返回文字。音频可能是静音，请检查收音状态；录音仍保留，可在会后重新转写。"
        }
    }
}

@MainActor
private final class RecognitionStream {
    let id = UUID()
    let request: SFSpeechAudioBufferRecognitionRequest
    let source: String
    var offset: Double
    var audioDuration: Double = 0
    var task: SFSpeechRecognitionTask?
    var deadline: Task<Void, Never>?
    var receivedAudio = false
    var ended = false
    var segmentIDs: [Int: UUID] = [:]
    var latest: [Int: RecognizedChunk] = [:]

    init(request: SFSpeechAudioBufferRecognitionRequest, source: String, offset: Double) {
        self.request = request
        self.source = source
        self.offset = offset
    }
}

private struct RecognizedChunk {
    let segment: TranscriptSegment
    let finalized: Bool
}
