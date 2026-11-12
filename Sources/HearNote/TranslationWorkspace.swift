#if os(macOS)
import AppKit
import AVFoundation
import Combine
import Foundation
import HearNoteCore
import NaturalLanguage
import UniformTypeIdentifiers
import Vision

enum TranslationMode: String, CaseIterable, Identifiable {
    case text = "文字"
    case conversation = "对话"

    var id: String { rawValue }
}

/// 独立翻译页的状态。音频与图片只在 Mac 上识别，Bedrock 仅接收用户确认的文字。
@MainActor
final class TranslationWorkspace: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static var sourceLanguages: [String] {
        ["自动识别"] + BedrockClient.supportedLanguages.filter { $0 != BedrockClient.bilingualLanguage }
    }
    static var targetLanguages: [String] { BedrockClient.supportedLanguages }

    @Published var inputText = "" {
        didSet {
            guard inputText != oldValue, !isUpdatingFields else { return }
            invalidateInputWork()
        }
    }
    @Published private(set) var outputText = ""
    @Published var sourceLanguage = "自动识别" {
        didSet {
            guard sourceLanguage != oldValue, !isUpdatingFields else { return }
            invalidateInputWork()
        }
    }
    @Published var targetLanguage = BedrockClient.bilingualLanguage {
        didSet {
            guard targetLanguage != oldValue, !isUpdatingFields else { return }
            invalidateInputWork()
        }
    }
    @Published var mode: TranslationMode = .text
    @Published private(set) var isTranslating = false
    @Published private(set) var isListening = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isFinishingVoice = false
    @Published private(set) var isRecognizingImage = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var status = ""
    @Published var errorMessage: String?
    @Published private(set) var historyWarning = ""
    @Published private(set) var lastLatency: Double?
    @Published private(set) var entries: [TranslationEntry] = []
    @Published var historyFavoritesOnly = false

    private weak var state: AppState?
    private let history: TranslationHistoryRepository
    private let historyQueue = DispatchQueue(label: "app.hearnote.translation-history")
    private let historyWriteGate = TranslationHistoryWriteGate()
    private var historyPersistenceHealthy = true
    private var isUpdatingFields = false
    private var displayedEntry: TranslationEntry?

    private var translationTask: Task<Void, Never>?
    private var translationID: UUID?
    private var voiceTask: Task<Void, Never>?
    private var voiceID: UUID?
    private var whisperRecognizer: WhisperLiveRecognizer?
    private var appleRecognizer: LiveSpeechRecognizer?
    private var voiceBackendDescription = ""
    private var voiceSegments: [UUID: TranscriptSegment] = [:]
    private var voiceRecognitionFailed = false
    private var engine: AVAudioEngine?
    private var engineConfigurationObserver: NSObjectProtocol?

    private var imageTask: Task<Void, Never>?
    private var imageWorker: Task<String, Error>?
    private var imageOperation: TranslationImageOperation?
    private var imageID: UUID?

    private let synthesizer = AVSpeechSynthesizer()
    private var speechUtterances: Set<ObjectIdentifier> = []

    init(state: AppState) {
        self.state = state
        history = TranslationHistoryRepository(root: state.root)
        super.init()
        synthesizer.delegate = self
        do {
            let loaded = try history.load()
            guard loaded.count <= 200, Set(loaded.map(\.id)).count == loaded.count else {
                throw TranslationWorkspaceIssue("翻译历史超过容量或包含重复记录。")
            }
            entries = loaded.sorted { $0.createdAt > $1.createdAt }
        } catch {
            historyPersistenceHealthy = false
            historyWriteGate.disable()
            historyWarning = "翻译历史无法读取，原文件已保留并停止写入。新的译文和收藏仅保留在当前会话，未保存；请先备份并检查历史文件。"
        }
    }

    var busy: Bool {
        isTranslating || isUsingSpeech || isRecognizingImage
    }
    var isUsingSpeech: Bool {
        isListening || isPreparing || isFinishingVoice
    }
    var canSwap: Bool {
        sourceLanguage != "自动识别" &&
            targetLanguage != BedrockClient.bilingualLanguage &&
            sourceLanguage != targetLanguage
    }
    var visibleEntries: [TranslationEntry] {
        entries.filter { !historyFavoritesOnly || $0.isFavorite }
    }
    var currentIsFavorite: Bool {
        guard let current = displayedEntry else { return false }
        return entries.first(where: { $0.id == current.id })?.isFavorite ?? current.isFavorite
    }

    func translate() {
        guard !isUsingSpeech, !isRecognizingImage else {
            errorMessage = "请先结束语音输入或图片识别。"
            return
        }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "请先输入要翻译的文字。"
            return
        }
        guard let state, !state.isQuitting else { return }
        cancelTranslation()
        stopSpeaking()
        errorMessage = nil
        outputText = ""
        displayedEntry = nil
        lastLatency = nil

        do {
            let client = try state.makeClient()
            let source = sourceLanguage
            let target = targetLanguage
            let configuration = state.preferences.configuration
            let inputSnapshot = inputText
            let id = UUID()
            translationID = id
            isTranslating = true
            status = "正在翻译…"
            translationTask = Task { [weak self] in
                let started = Date()
                do {
                    let output = try await client.translateText(
                        text, sourceLanguage: source, targetLanguage: target
                    )
                    try Task.checkCancellation()
                    guard let self, self.translationID == id,
                          self.inputText == inputSnapshot,
                          self.sourceLanguage == source, self.targetLanguage == target,
                          self.state?.preferences.configuration == configuration,
                          self.state?.isQuitting == false else { return }
                    self.outputText = output
                    self.lastLatency = Date().timeIntervalSince(started)
                    let entry = TranslationEntry(
                        sourceText: text, translatedText: output,
                        sourceLanguage: source, targetLanguage: target,
                        modelID: configuration.modelID
                    )
                    self.displayedEntry = entry
                    let retained = self.insertHistory(entry)
                    if !self.historyPersistenceHealthy {
                        self.status = "翻译完成；本次译文和收藏仅保留在当前会话，未保存。"
                    } else {
                        self.status = retained ? "翻译完成" : "翻译完成；历史已有 200 条收藏，本次未加入历史。"
                    }
                    self.finishTranslation(id)
                } catch is CancellationError {
                    self?.finishTranslation(id)
                } catch {
                    guard !Task.isCancelled, let self, self.translationID == id else { return }
                    self.errorMessage = error.localizedDescription
                    self.status = "翻译未完成"
                    self.finishTranslation(id)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            status = "请检查翻译配置"
        }
    }

    func cancel() {
        cancelTranslation()
        cancelVoice()
        cancelImage()
        stopSpeaking()
        status = "已取消，已有文字保留"
    }

    func clear() {
        cancel()
        updateFields {
            inputText = ""
            outputText = ""
        }
        displayedEntry = nil
        lastLatency = nil
        errorMessage = nil
        status = ""
    }

    func swapLanguages() {
        guard canSwap else { return }
        let oldSource = sourceLanguage
        let oldTarget = targetLanguage
        let newInput = outputText.isEmpty ? inputText : outputText
        cancel()
        updateFields {
            sourceLanguage = oldTarget
            targetLanguage = oldSource
            inputText = newInput
            outputText = ""
        }
        displayedEntry = nil
        lastLatency = nil
        errorMessage = nil
        status = ""
    }

    func configurationChanged() {
        invalidateInputWork()
        status = "翻译配置已更新"
    }

    func toggleFavorite(_ entry: TranslationEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].isFavorite.toggle()
        if displayedEntry?.id == entry.id { displayedEntry = entries[index] }
        persistHistory()
        if !historyPersistenceHealthy { status = "收藏变更仅保留在当前会话，未保存。" }
    }

    func toggleCurrentFavorite() {
        guard var current = displayedEntry else { return }
        if let saved = entries.first(where: { $0.id == current.id }) {
            toggleFavorite(saved)
            return
        }
        // 收藏已占满历史时，译文仍可显示；不能为了再收藏静默丢弃旧收藏。
        guard entries.filter(\.isFavorite).count < 200 else {
            errorMessage = "已收藏 200 条。请先取消一条收藏，再收藏本次译文。"
            return
        }
        current.isFavorite = true
        displayedEntry = current
        _ = insertHistory(current)
        if !historyPersistenceHealthy { status = "本次收藏仅保留在当前会话，未保存。" }
    }

    func restore(_ entry: TranslationEntry) {
        cancel()
        updateFields {
            sourceLanguage = entry.sourceLanguage
            targetLanguage = entry.targetLanguage
            inputText = entry.sourceText
            outputText = entry.translatedText
        }
        displayedEntry = entry
        lastLatency = nil
        errorMessage = nil
        status = "已打开历史译文"
    }

    func copyOutput() {
        guard !outputText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputText, forType: .string)
        status = "译文已复制"
    }

    func startVoice(sourceLanguage source: String, targetLanguage target: String) {
        guard let state, !state.isQuitting else { return }
        guard !state.recorder.isRecording, !state.isBusy,
              !state.mixedSpeech.isTranscribing, !state.mixedSpeech.isPreparing else {
            errorMessage = "请先结束会议录音、文件转写或模型准备，再开始语音翻译。"
            return
        }
        guard !busy else {
            errorMessage = "请先完成或取消当前翻译任务。"
            return
        }
        let source = Self.normalizedLanguage(source)
        let target = Self.normalizedLanguage(target)
        guard Self.sourceLanguages.contains(source), Self.targetLanguages.contains(target) else {
            errorMessage = "请选择支持的原文和译文语言。"
            return
        }
        cancel()
        updateFields {
            sourceLanguage = source
            targetLanguage = target
            inputText = ""
            outputText = ""
        }
        displayedEntry = nil
        lastLatency = nil
        errorMessage = nil
        voiceSegments.removeAll()
        voiceRecognitionFailed = false
        let id = UUID()
        voiceID = id
        isPreparing = true
        let modelVariant = state.preferences.whisperModel
        let terms = state.preferences.contextualStrings
        let speechLocale = Self.localeForLanguage(source)
        // 独立翻译按这里明确选择的原文语言识别，不使用会议的中英混合配置覆盖它。
        let useApple = state.preferences.speechEngine == .apple && speechLocale != nil
        let allowCloudRecognition = state.preferences.allowCloudRecognition
        let apple = useApple ? LiveSpeechRecognizer() : nil
        let whisper = useApple ? nil : state.mixedSpeech.makeLiveRecognizer()
        appleRecognizer = apple
        whisperRecognizer = whisper
        if let apple {
            voiceBackendDescription = apple.backendDescription
            apple.onError = { [weak self] error in self?.voiceFailed(error, id: id) }
            apple.onStatusChange = { [weak self, weak apple] recognitionStatus in
                guard let self, let apple, self.voiceID == id,
                      !self.voiceRecognitionFailed else { return }
                self.voiceBackendDescription = apple.backendDescription
                let backendPrefix = "\(apple.backendDescription) · "
                self.status = recognitionStatus.hasPrefix(backendPrefix)
                    ? recognitionStatus : backendPrefix + recognitionStatus
            }
        } else if let whisper {
            switch modelVariant {
            case WhisperSpeechService.defaultModelVariant:
                voiceBackendDescription = "本地 Whisper Large v3 Turbo"
            case "small":
                voiceBackendDescription = "本地 Whisper Small"
            default:
                voiceBackendDescription = "本地 Whisper"
            }
            whisper.onError = { [weak self] error in self?.voiceFailed(error, id: id) }
        }
        status = "\(voiceBackendDescription) · 正在准备语音识别…"
        let update: (TranscriptSegment, Bool) -> Void = { [weak self] segment, _ in
            guard let self, self.voiceID == id else { return }
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.voiceSegments.removeValue(forKey: segment.id)
            } else {
                self.voiceSegments[segment.id] = segment
            }
            self.updateFields { self.inputText = self.recognizedText }
        }
        voiceTask = Task { [weak self, weak state] in
            do {
                try await Self.authorizeMicrophone()
                try Task.checkCancellation()
                guard let self, let state, self.voiceID == id else { return }
                if let apple, let speechLocale {
                    try await apple.start(
                        locale: speechLocale, allowCloudRecognition: allowCloudRecognition,
                        contextualStrings: terms, source: "语音翻译", onUpdate: update
                    )
                    self.voiceBackendDescription = apple.backendDescription
                } else if let whisper {
                    try await state.mixedSpeech.prepare(modelVariant: modelVariant)
                    try Task.checkCancellation()
                    guard self.voiceID == id, !state.isQuitting,
                          !state.recorder.isRecording, !state.isBusy else {
                        throw CancellationError()
                    }
                    try await whisper.start(
                        contextualStrings: terms, source: "语音翻译",
                        locale: speechLocale ?? "auto", onUpdate: update
                    )
                }
                try Task.checkCancellation()
                guard self.voiceID == id, !state.isQuitting,
                      !state.recorder.isRecording, !state.isBusy else {
                    throw CancellationError()
                }
                try self.startMicrophone(id: id) { [weak apple, weak whisper] buffer in
                    if let apple { apple.append(buffer) }
                    else { whisper?.append(buffer) }
                }
                self.isPreparing = false
                self.isListening = true
                self.voiceTask = nil
                self.status = "\(self.voiceBackendDescription) · 正在聆听，说完后点击“结束并翻译”"
            } catch is CancellationError {
                guard let self, self.voiceID == id else { return }
                self.cancelVoice()
            } catch {
                guard !Task.isCancelled, let self, self.voiceID == id else { return }
                self.voiceFailed(error, id: id)
            }
        }
    }

    func stopVoiceAndTranslate() {
        guard isListening, let id = voiceID,
              whisperRecognizer != nil || appleRecognizer != nil else { return }
        let whisper = whisperRecognizer
        let apple = appleRecognizer
        isListening = false
        isFinishingVoice = true
        stopMicrophone()
        status = "\(voiceBackendDescription) · 正在识别最后一句…"
        voiceTask = Task { [weak self] in
            // tap 的 PCM 副本在主队列投递；停止引擎后用队列屏障先收完已排队的最后一批。
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard let self, self.voiceID == id, !Task.isCancelled else { return }
            if let apple { await apple.finish() }
            else { await whisper?.finish() }
            guard self.voiceID == id, !Task.isCancelled else { return }
            self.updateFields { self.inputText = self.recognizedText }
            let failed = self.voiceRecognitionFailed
            self.voiceID = nil
            whisper?.onError = nil
            apple?.onError = nil
            apple?.onStatusChange = nil
            self.whisperRecognizer = nil
            self.appleRecognizer = nil
            self.voiceTask = nil
            self.isFinishingVoice = false
            self.isPreparing = false
            guard !failed else {
                self.status = "已有原文保留，请校对后翻译"
                return
            }
            guard !self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.errorMessage = "没有识别到语音。请检查麦克风后重试。"
                self.status = "未识别到文字"
                return
            }
            self.translate()
        }
    }

    func cancelVoice() {
        let wasActive = isUsingSpeech
        voiceID = nil
        voiceTask?.cancel()
        voiceTask = nil
        stopMicrophone()
        whisperRecognizer?.onError = nil
        whisperRecognizer?.cancel()
        whisperRecognizer = nil
        appleRecognizer?.onError = nil
        appleRecognizer?.onStatusChange = nil
        appleRecognizer?.cancel()
        appleRecognizer = nil
        voiceBackendDescription = ""
        isListening = false
        isPreparing = false
        isFinishingVoice = false
        if wasActive { status = "语音输入已取消，已识别文字保留" }
    }

    func importImage() {
        guard !isUsingSpeech else {
            errorMessage = "请先结束语音输入。"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择要识别文字的图片"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        invalidateInputWork()
        errorMessage = nil
        let id = UUID()
        imageID = id
        isRecognizingImage = true
        status = "正在本地识别图片文字…"
        let operation = TranslationImageOperation(
            url: url, customWords: state?.preferences.contextualStrings ?? []
        )
        imageOperation = operation
        let worker = Task.detached(priority: .userInitiated) {
            try operation.recognize()
        }
        imageWorker = worker
        imageTask = Task { [weak self] in
            do {
                let text = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    operation.cancel()
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard let self, self.imageID == id else { return }
                self.updateFields { self.inputText = text }
                self.status = "图片文字已识别，请校对后点击翻译"
                self.finishImage(id)
            } catch is CancellationError {
                self?.finishImage(id)
            } catch {
                guard !Task.isCancelled, let self, self.imageID == id else { return }
                self.errorMessage = error.localizedDescription
                self.status = "图片识别未完成"
                self.finishImage(id)
            }
        }
    }

    func speak(text: String, language: String) {
        guard !isUsingSpeech else {
            errorMessage = "请先结束语音输入再朗读。"
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stopSpeaking()
        errorMessage = nil
        let language = Self.normalizedLanguage(language)
        let automatic = language == "自动识别" || language == BedrockClient.bilingualLanguage
        let pieces = automatic ? text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } : [text]
        var prepared: [AVSpeechUtterance] = []
        for rawPiece in pieces {
            let piece = language == BedrockClient.bilingualLanguage
                ? rawPiece.replacingOccurrences(of: #"^\s*(?:英文|中文)[：:]\s*"#,
                                                with: "", options: .regularExpression)
                : rawPiece
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let locale: String?
            if automatic {
                let detector = NLLanguageRecognizer()
                detector.processString(piece)
                locale = detector.dominantLanguage.map { Self.speechLocale(for: $0) }
            } else {
                locale = Self.localeForLanguage(language)
            }
            guard let locale else {
                errorMessage = "无法判断朗读语言，请选择明确的语言。"
                return
            }
            guard let voice = Self.installedVoice(locale: locale) else {
                errorMessage = "这台 Mac 尚未安装对应的朗读声音。请在系统设置中添加该语言的声音后重试。"
                return
            }
            let utterance = AVSpeechUtterance(string: piece)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            prepared.append(utterance)
        }
        guard !prepared.isEmpty else { return }
        speechUtterances = Set(prepared.map(ObjectIdentifier.init))
        isSpeaking = true
        for utterance in prepared { synthesizer.speak(utterance) }
    }

    func stopSpeaking() {
        speechUtterances.removeAll()
        isSpeaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                     didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                     didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.finishedSpeaking(utterance) }
    }

    /// 页面切换可再次打开；close 只释放资源，不永久禁用这个工作区。
    func close() {
        cancelTranslation()
        cancelVoice()
        cancelImage()
        stopSpeaking()
        status = ""
    }

    func finishForQuit() async {
        close()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            historyQueue.async { continuation.resume() }
        }
    }

    private var recognizedText: String {
        voiceSegments.values.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id.uuidString < $1.id.uuidString
        }.map(\.text).joined(separator: "\n")
    }

    private func invalidateInputWork() {
        cancelTranslation()
        cancelVoice()
        cancelImage()
        stopSpeaking()
        outputText = ""
        displayedEntry = nil
        lastLatency = nil
        errorMessage = nil
        status = ""
    }

    private func updateFields(_ action: () -> Void) {
        isUpdatingFields = true
        defer { isUpdatingFields = false }
        action()
    }

    private func cancelTranslation() {
        translationID = nil
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }

    private func finishTranslation(_ id: UUID) {
        guard translationID == id else { return }
        translationID = nil
        translationTask = nil
        isTranslating = false
    }

    private func cancelImage() {
        imageID = nil
        imageOperation?.cancel()
        imageTask?.cancel()
        imageWorker?.cancel()
        imageTask = nil
        imageWorker = nil
        imageOperation = nil
        isRecognizingImage = false
    }

    private func finishImage(_ id: UUID) {
        guard imageID == id else { return }
        imageID = nil
        imageTask = nil
        imageWorker = nil
        imageOperation = nil
        isRecognizingImage = false
    }

    @discardableResult
    private func insertHistory(_ entry: TranslationEntry) -> Bool {
        var updated = entries.filter { $0.id != entry.id }
        updated.insert(entry, at: 0)
        updated.sort { $0.createdAt > $1.createdAt }
        let favoriteIDs = Set(updated.filter(\.isFavorite).map(\.id))
        let remaining = max(0, 200 - favoriteIDs.count)
        let recentIDs = Set(updated.filter { !$0.isFavorite }.prefix(remaining).map(\.id))
        entries = updated.filter { favoriteIDs.contains($0.id) || recentIDs.contains($0.id) }
        persistHistory()
        return entries.contains { $0.id == entry.id }
    }

    private func persistHistory() {
        guard historyPersistenceHealthy else {
            if historyWarning.isEmpty {
                historyWarning = "翻译历史已停止写入以保护原文件。新的译文和收藏仅保留在当前会话，未保存；请先备份并检查历史文件。"
            }
            return
        }
        let snapshot = entries
        let history = history
        let writeGate = historyWriteGate
        historyQueue.async { [weak self] in
            guard writeGate.isEnabled else { return }
            do { try history.save(entries: snapshot) }
            catch {
                // 在同一个串行写队列立即关闭，已排队的后续快照也不能继续写。
                writeGate.disable()
                Task { @MainActor in
                    guard let self else { return }
                    self.historyPersistenceHealthy = false
                    self.historyWarning = "翻译历史保存失败，已停止后续写入。新的译文和收藏仅保留在当前会话，未保存；已有译文仍可复制。请先备份并检查历史文件。"
                    if !self.busy, !self.outputText.isEmpty {
                        self.status = "当前译文和收藏变更仅保留在当前会话，未保存。"
                    }
                }
            }
        }
    }

    private func startMicrophone(
        id: UUID, append: @escaping @MainActor (AVAudioPCMBuffer) -> Void
    ) throws {
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw TranslationWorkspaceIssue("当前麦克风不可用，请检查输入设备。")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let copied = TranslationAudioBuffer.copy(buffer) else { return }
            DispatchQueue.main.async {
                guard let self, self.voiceID == id,
                      self.isListening || self.isFinishingVoice else { return }
                append(copied)
            }
        }
        engine = newEngine
        do {
            newEngine.prepare()
            try newEngine.start()
            engineConfigurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.voiceFailed(
                        TranslationWorkspaceIssue("输入设备发生变化，语音输入已停止；已识别文字保留。"),
                        id: id
                    )
                }
            }
        } catch {
            stopMicrophone()
            throw error
        }
    }

    private func stopMicrophone() {
        if let observer = engineConfigurationObserver {
            NotificationCenter.default.removeObserver(observer)
            engineConfigurationObserver = nil
        }
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private func voiceFailed(_ error: Error, id: UUID) {
        guard voiceID == id else { return }
        voiceRecognitionFailed = true
        let finishing = isFinishingVoice
        stopMicrophone()
        isListening = false
        isPreparing = false
        if let whisperError = error as? WhisperSpeechError {
            switch whisperError {
            case .decodingBacklog:
                errorMessage = "本地识别跟不上语音，已停止输入并保留已有文字。可尝试较小的识别模型。"
            case .finishingTimedOut:
                errorMessage = "最后一段语音识别超时，已有文字保留。请校对后再翻译。"
            case .audioConversion:
                errorMessage = "麦克风音频无法转换，已停止输入并保留已有文字。"
            default:
                errorMessage = whisperError.localizedDescription
            }
        } else {
            errorMessage = error.localizedDescription
        }
        status = "已有原文保留，请校对后翻译"
        if !finishing {
            cancelVoice()
            status = "已有原文保留，请校对后翻译"
        }
    }

    private static func authorizeMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw TranslationWorkspaceIssue("请在系统设置的麦克风权限中允许听记。")
            }
        default:
            throw TranslationWorkspaceIssue("请在系统设置的麦克风权限中允许听记。")
        }
    }

    private func finishedSpeaking(_ utterance: AVSpeechUtterance) {
        guard speechUtterances.remove(ObjectIdentifier(utterance)) != nil else { return }
        isSpeaking = !speechUtterances.isEmpty
    }

    private static func normalizedLanguage(_ language: String) -> String {
        language == "中文" ? "简体中文" : language
    }

    private static func localeForLanguage(_ language: String) -> String? {
        switch language {
        case "简体中文": return "zh-CN"
        case "繁体中文": return "zh-TW"
        case "英文": return "en-US"
        case "日文": return "ja-JP"
        case "韩文": return "ko-KR"
        case "法文": return "fr-FR"
        case "德文": return "de-DE"
        case "西班牙文": return "es-ES"
        default: return nil
        }
    }

    private static func speechLocale(for language: NLLanguage) -> String {
        switch language {
        case .simplifiedChinese: return "zh-CN"
        case .traditionalChinese: return "zh-TW"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .korean: return "ko-KR"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .spanish: return "es-ES"
        default: return language.rawValue
        }
    }

    private static func installedVoice(locale: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let exact = voices.first(where: { $0.language.caseInsensitiveCompare(locale) == .orderedSame }) {
            return exact
        }
        // 中文保持简/繁地区选择，不能把两种中文声音混用。
        if locale.hasPrefix("zh-") { return nil }
        let prefix = locale.split(separator: "-").first.map(String.init) ?? locale
        return voices.first { $0.language.split(separator: "-").first.map(String.init) == prefix }
    }
}

private struct TranslationWorkspaceIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class TranslationHistoryWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func disable() {
        lock.lock()
        enabled = false
        lock.unlock()
    }
}

/// tap 会复用传入的内存；在离开回调前复制 PCM，再交给主队列的多语种识别器。
private enum TranslationAudioBuffer {
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copied = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                           frameCapacity: buffer.frameLength) else { return nil }
        copied.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { return nil }
            memcpy(destinationData, sourceData,
                   Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copied
    }
}

/// Vision perform 在后台同步执行；请求取消与 generation 检查分别处理执行取消和晚到结果。
private final class TranslationImageOperation: @unchecked Sendable {
    private let url: URL
    private let customWords: [String]
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRecognizeTextRequest?

    init(url: URL, customWords: [String]) {
        self.url = url
        self.customWords = Array(customWords.prefix(100))
    }

    func recognize() throws -> String {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        let preferred = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"]
        request.recognitionLanguages = preferred.filter { supported.contains($0) }
        request.customWords = customWords
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            throw CancellationError()
        }
        self.request = request
        lock.unlock()
        defer {
            lock.lock()
            self.request = nil
            lock.unlock()
        }
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        try Task.checkCancellation()
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled else { throw CancellationError() }
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw TranslationWorkspaceIssue("没有识别到图片文字。请换一张清晰、方向正确的图片。")
        }
        return text
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let activeRequest = request
        lock.unlock()
        activeRequest?.cancel()
    }
}
#endif
