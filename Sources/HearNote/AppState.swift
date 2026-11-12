#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import HearNoteCore

struct SavedModel: Identifiable, Codable, Equatable {
    var id: String { modelID }
    var name: String
    var modelID: String
}

enum SpeechRecognitionEngine: String, Codable {
    case whisper
    case apple
}

struct AppPreferences: Codable {
    static let defaultModel = SavedModel(
        name: "Claude Sonnet 5.5", modelID: "global.anthropic.claude-sonnet-5-5"
    )
    static let kimiModel = SavedModel(
        name: "Kimi K3", modelID: "global.moonshotai.kimi-k3"
    )
    static let glmModel = SavedModel(
        name: "GLM 5.3", modelID: "global.zai.glm-5.3"
    )
    static let gptModel = SavedModel(
        name: "GPT 5.6 Sol", modelID: "global.openai.gpt-5.6-sol"
    )
    var region = "ap-northeast-1"
    // 固定已核实的最新 Sonnet 版本；当前 key 权限仍以连接测试为准。
    var modelID = Self.defaultModel.modelID
    var models: [SavedModel] = [
        Self.defaultModel, Self.kimiModel, Self.glmModel, Self.gptModel
    ]
    private var modelPresetVersion = 2
    var speechLocale = "zh-en"
    var speechEngine = SpeechRecognitionEngine.whisper
    var targetLanguage = BedrockClient.bilingualLanguage
    var whisperModel = "large-v3-v20240930_turbo"
    var allowCloudRecognition = false
    var vocabulary = ""
    var glossary = ""
    var hasCompletedSetup = false
    init() {}
    private enum CodingKeys: String, CodingKey {
        case region, modelID, models, modelPresetVersion, speechLocale, speechEngine, targetLanguage, whisperModel
        case allowCloudRecognition, vocabulary, glossary, hasCompletedSetup
    }
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        region = try saved.decodeIfPresent(String.self, forKey: .region) ?? region
        modelID = try saved.decodeIfPresent(String.self, forKey: .modelID) ?? modelID
        models = try saved.decodeIfPresent([SavedModel].self, forKey: .models) ?? models
        modelPresetVersion = try saved.decodeIfPresent(Int.self, forKey: .modelPresetVersion) ?? 0
        speechLocale = try saved.decodeIfPresent(String.self, forKey: .speechLocale) ?? speechLocale
        speechEngine = try saved.decodeIfPresent(SpeechRecognitionEngine.self, forKey: .speechEngine) ?? .whisper
        targetLanguage = try saved.decodeIfPresent(String.self, forKey: .targetLanguage) ?? targetLanguage
        whisperModel = try saved.decodeIfPresent(String.self, forKey: .whisperModel) ?? whisperModel
        allowCloudRecognition = try saved.decodeIfPresent(Bool.self, forKey: .allowCloudRecognition) ?? allowCloudRecognition
        vocabulary = try saved.decodeIfPresent(String.self, forKey: .vocabulary) ?? vocabulary
        glossary = try saved.decodeIfPresent(String.self, forKey: .glossary) ?? glossary
        hasCompletedSetup = try saved.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? hasCompletedSetup
        migrateModelPresets()
    }
    private mutating func migrateModelPresets() {
        guard modelPresetVersion < 2 else { return }
        var replacements: [String: SavedModel] = [
            "global.moonshotai.kimi-k3.1": Self.kimiModel
        ]
        if modelPresetVersion < 1 {
            replacements["global.anthropic.claude-sonnet-4-6"] = Self.defaultModel
            replacements["qwen.qwen3-235b-a22b-2507-v1:0"] = Self.kimiModel
            replacements["qwen.qwen3-next-80b-a3b"] = Self.kimiModel
        }
        // 更新旧内置型号，同时保留其他自定义型号、Region 和所有语音设置。
        var upgraded: [SavedModel] = []
        for model in models {
            let current = replacements[model.modelID] ?? model
            if !upgraded.contains(where: { $0.modelID == current.modelID }) {
                upgraded.append(current)
            }
        }
        if let replacement = replacements[modelID] {
            modelID = replacement.modelID
            if !upgraded.contains(where: { $0.modelID == replacement.modelID }) {
                upgraded.append(replacement)
            }
        }
        if modelPresetVersion < 1 {
            for candidate in [Self.glmModel, Self.gptModel] {
                if !upgraded.contains(where: { $0.modelID == candidate.modelID }) {
                    upgraded.append(candidate)
                }
            }
        }
        models = upgraded
        modelPresetVersion = 2
    }
    var configuration: BedrockConfiguration {
        BedrockConfiguration(region: region, modelID: modelID)
    }
    var usesWhisperRecognition: Bool { speechLocale == "zh-en" || speechEngine == .whisper }
    var contextualStrings: [String] {
        vocabulary.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == "，" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    var translationGlossary: [String: String] {
        var result: [String: String] = [:]
        for line in glossary.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let left = pair[0].trimmingCharacters(in: .whitespaces)
            let right = pair[1].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty && !right.isEmpty { result[left] = right }
        }
        return result
    }
}

enum DetailTab: String, CaseIterable {
    case comparison = "对照"
    case transcript = "原文"
    case translation = "翻译"
    case summary = "摘要"
}

enum WorkspaceTab {
    case notes
    case translation
}

@MainActor
final class AppState: ObservableObject {
    @Published var documents: [NoteDocument] = []
    @Published var selection: UUID?
    @Published var searchText = ""
    @Published var favoritesOnly = false
    @Published var preferences = AppPreferences()
    @Published var showSettings = false
    @Published var showRecording = false
    @Published var workspaceTab = WorkspaceTab.notes
    @Published var detailTab = DetailTab.transcript
    @Published var errorMessage: String?
    @Published var busyMessage: String?
    @Published var lastLatency: Double?
    @Published var liveTranslations: [UUID: String] = [:]
    @Published var liveTranslationStatus = ""
    @Published private(set) var translatingSegment: TranscriptSegment?
    @Published private(set) var liveTranslationError: String?
    @Published var liveRecognitionWarning = ""
    @Published private(set) var liveRecognitionStatus = ""
    @Published private(set) var isPreparingMeetingRecognition = false
    @Published var translateLive = true
    @Published var liveDocumentID: UUID?
    @Published var recordingSource = RecordingSource.both
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false
    @Published var isImporting = false
    @Published var isQuitting = false
    let player = MediaPlayer()
    let recorder = MeetingRecorder()
    let transcriber = SpeechTranscriber()
    let mixedSpeech = WhisperSpeechService()
    lazy var translationWorkspace = TranslationWorkspace(state: self)
    private let microphoneSpeech = LiveSpeechRecognizer()
    private let systemSpeech = LiveSpeechRecognizer()
    private lazy var microphoneMixedSpeech = mixedSpeech.makeLiveRecognizer()
    private lazy var systemMixedSpeech = mixedSpeech.makeLiveRecognizer()
    let repository: DocumentRepository
    let root: URL
    @Published private var workTask: Task<Void, Never>?
    private var liveTranslationTask: Task<Void, Never>?
    private var meetingRecognitionTask: Task<Void, Never>?
    private var meetingRecognitionID: UUID?
    private var recognitionWarnings: [String: String] = [:]
    private var translationQueue = LiveTranslationQueue()
    private var isTranslatingLive = false
    private var lastPersistence = Date.distantPast
    private var meetingUsesWhisper = false
    private var persistenceHealthy = true
    private let persistenceQueue = DispatchQueue(label: "app.hearnote.persistence")

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("HearNote", isDirectory: true)
        repository = DocumentRepository(root: root)
        if let data = UserDefaults.standard.data(forKey: "HearNote.preferences"),
           let saved = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            preferences = saved
        }
        do {
            documents = try repository.load()
            if documents.isEmpty && !UserDefaults.standard.bool(forKey: "HearNote.seeded") {
                documents = [SampleData.document]
                try repository.save(documents)
                UserDefaults.standard.set(true, forKey: "HearNote.seeded")
            }
            selection = documents.first?.id
        } catch {
            persistenceHealthy = false
            errorMessage = "无法读取已有记录，已停止写入以保护原文件。请先备份并检查 \(root.path)。\n\(error.localizedDescription)"
        }
    }

    var selectedDocument: NoteDocument? { documents.first { $0.id == selection } }
    var visibleDocuments: [NoteDocument] {
        documents.filter {
            (!favoritesOnly || $0.isFavorite) &&
            (searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) ||
             $0.plainText.localizedCaseInsensitiveContains(searchText))
        }.sorted { $0.createdAt > $1.createdAt }
    }
    var activeModelName: String {
        preferences.models.first { $0.modelID == preferences.modelID }?.name ?? "选择模型"
    }
    var isBusy: Bool { workTask != nil || isImporting || isStartingRecording || isStoppingRecording }
    var canCancelWork: Bool { workTask != nil }
    var recordingDirectory: URL { root.appendingPathComponent("Recording", isDirectory: true) }

    private var noteActionContext: NoteActionContext {
        NoteActionContext(
            isQuitting: isQuitting,
            isStartingRecording: isStartingRecording,
            isStoppingRecording: isStoppingRecording,
            isRecording: recorder.isRecording || liveDocumentID != nil,
            isImporting: isImporting,
            isProcessing: workTask != nil
        )
    }
    func aiBlockReason(for document: NoteDocument) -> NoteActionBlockReason? {
        noteActionContext.aiBlockReason(hasTranscript: document.hasTranscriptText)
    }
    func transcriptionBlockReason(for document: NoteDocument) -> NoteActionBlockReason? {
        noteActionContext.transcriptionBlockReason(hasMedia: document.mediaFilename != nil)
    }
    func actionBlockMessage(_ reason: NoteActionBlockReason) -> String {
        if reason == .processing, let busyMessage { return busyMessage }
        return reason.message
    }

    func presentSetupIfNeeded() {
        if !preferences.hasCompletedSetup { showSettings = true }
    }
    func openMeetingWorkspace() {
        guard !isQuitting else { return }
        workspaceTab = .notes
        showRecording = true
        if let id = liveDocumentID {
            selection = id
            player.stop()
        }
    }
    func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: "HearNote.preferences")
    }
    func savePreferences(_ value: AppPreferences, apiKey: String) throws {
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try KeychainStore.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        translationWorkspace.configurationChanged()
        preferences = value
        preferences.hasCompletedSetup = true
        persistPreferences()
    }
    func selectRegion(_ region: String) {
        translationWorkspace.configurationChanged()
        preferences.region = region
        persistPreferences()
    }
    func selectModel(_ id: String) {
        translationWorkspace.configurationChanged()
        preferences.modelID = id
        persistPreferences()
    }
    func makeClient(preferences value: AppPreferences? = nil, key: String? = nil) throws -> BedrockClient {
        let value = value ?? preferences
        guard value.configuration.isConfigured else {
            throw AppIssue("请先在设置中填写 Region 和模型 ID。")
        }
        let apiKey = try key ?? KeychainStore.loadAPIKey() ?? ""
        guard !apiKey.isEmpty else { throw AppIssue("请先在设置中保存 Bedrock API key。") }
        return BedrockClient(configuration: value.configuration, apiKey: apiKey, glossary: value.translationGlossary)
    }
    func persist() {
        guard persistenceHealthy else { return }
        let snapshot = documents
        let repository = self.repository
        persistenceQueue.async { [weak self] in
            do { try repository.save(snapshot) }
            catch {
                let message = "记录保存失败：\(error.localizedDescription)"
                Task { @MainActor in self?.errorMessage = message }
            }
        }
    }
    func updateDocument(_ id: UUID, _ edit: (inout NoteDocument) -> Void) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        edit(&documents[index])
        persist()
    }
    func select(_ document: NoteDocument) {
        selection = document.id
        player.load(url: document.mediaFilename.map { repository.mediaURL(filename: $0) })
    }
    func updateText(documentID: UUID, segmentID: UUID, text: String) {
        updateDocument(documentID) { document in
            guard let index = document.segments.firstIndex(where: { $0.id == segmentID }),
                  document.segments[index].text != text else { return }
            document.segments[index].text = text
            // 编辑原文后，旧的翻译和摘要失效，避免展示不匹配的结果。
            document.segments[index].translation = nil
            document.translation = ""
            document.summary = ""
        }
    }
    func translationStatus(documentID: UUID, segment: TranscriptSegment) -> String {
        guard liveDocumentID == documentID else { return "未翻译" }
        if liveTranslationError != nil { return "翻译已暂停" }
        if !translateLive { return "实时翻译已关闭" }
        if translatingSegment?.id == segment.id && translatingSegment?.text == segment.text {
            return "正在翻译…"
        }
        if translationQueue.isWaitingForSentence(for: segment) { return "正在补全当前句…" }
        if translationQueue.isPending(for: segment) { return "等待译文…" }
        return "未翻译"
    }
    func removeDocument(_ id: UUID) {
        guard id != liveDocumentID, !isBusy else { return }
        documents.removeAll { $0.id == id }
        if selection == id {
            if let next = documents.first { select(next) }
            else { selection = nil; player.load(url: nil) }
        }
        persist()
    }
    func importDocument() {
        guard !recorder.isRecording, !isBusy, persistenceHealthy else { return }
        let panel = NSOpenPanel()
        panel.title = "导入音视频或文字"
        panel.allowedContentTypes = [.audio, .movie, .plainText]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.importURL(url) }
        }
    }
    private func importURL(_ url: URL) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let ext = url.pathExtension.lowercased()
            if ["txt", "md"].contains(ext) {
                let text = try await Task.detached {
                    try String(contentsOf: url, encoding: .utf8)
                }.value
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppIssue("这个文字文件是空的。")
                }
                let document = NoteDocument(
                    title: url.deletingPathExtension().lastPathComponent,
                    segments: [TranscriptSegment(start: 0, end: 0, text: text)],
                    sourceKind: .text
                )
                documents.insert(document, at: 0)
                select(document)
                workspaceTab = .notes
                showRecording = false
                persist()
                return
            }
            busyMessage = "正在导入音视频…"
            let repository = self.repository
            let filename = try await Task.detached { try repository.importMedia(from: url) }.value
            let localURL = repository.mediaURL(filename: filename)
            let asset = AVURLAsset(url: localURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw AppIssue("无法读取音视频时长，请检查文件格式。") }
            let kind: SourceKind = ["mp4", "mov", "m4v", "webm"].contains(ext) ? .video : .audio
            let document = NoteDocument(title: url.deletingPathExtension().lastPathComponent,
                                        mediaFilename: filename, duration: duration, sourceKind: kind)
            documents.insert(document, at: 0)
            select(document)
            workspaceTab = .notes
            showRecording = false
            persist()
            busyMessage = nil
            isImporting = false
            transcribeSelected()
        } catch {
            busyMessage = nil
            errorMessage = error.localizedDescription
        }
    }
    func transcribeSelected() {
        guard let document = selectedDocument else {
            errorMessage = "请先选择要转写的笔记。"
            return
        }
        if let reason = transcriptionBlockReason(for: document) {
            errorMessage = actionBlockMessage(reason)
            return
        }
        guard let filename = document.mediaFilename else { return }
        let locale = preferences.speechLocale
        let allowCloud = preferences.allowCloudRecognition
        let modelVariant = preferences.whisperModel
        let usesWhisper = preferences.usesWhisperRecognition
        let vocabulary = preferences.contextualStrings
        transcriber.contextualStrings = preferences.contextualStrings
        busyMessage = "正在转写，原文件保留在本机…"
        workTask = Task {
            defer {
                transcriber.onStatusChange = nil
                workTask = nil
                busyMessage = nil
            }
            do {
                let segments: [TranscriptSegment]
                if usesWhisper {
                    segments = try await mixedSpeech.transcribe(
                        url: repository.mediaURL(filename: filename),
                        contextualStrings: vocabulary, modelVariant: modelVariant, locale: locale
                    )
                } else {
                    transcriber.onStatusChange = { [weak self] status in
                        guard !Task.isCancelled else { return }
                        self?.busyMessage = status
                    }
                    segments = try await transcriber.transcribe(
                        url: repository.mediaURL(filename: filename), locale: locale,
                        allowCloudRecognition: allowCloud
                    )
                }
                guard !Task.isCancelled else { return }
                updateDocument(document.id) {
                    $0.segments = segments; $0.translation = ""; $0.summary = ""
                }
            } catch is CancellationError {
                let partial = usesWhisper ? mixedSpeech.partialSegments : transcriber.partialSegments
                if document.segments.isEmpty && !partial.isEmpty {
                    updateDocument(document.id) { $0.segments = partial }
                }
            } catch {
                let partial = usesWhisper ? mixedSpeech.partialSegments : transcriber.partialSegments
                if document.segments.isEmpty && !partial.isEmpty {
                    updateDocument(document.id) { $0.segments = partial }
                }
                errorMessage = error.localizedDescription
            }
        }
    }
    func runAI(_ tab: DetailTab) {
        guard tab == .translation || tab == .summary else { return }
        guard let document = selectedDocument else {
            errorMessage = "请先选择要处理的笔记。"
            return
        }
        if let reason = aiBlockReason(for: document) {
            errorMessage = actionBlockMessage(reason)
            return
        }
        do {
            let client = try makeClient()
            let language = preferences.targetLanguage
            detailTab = tab
            busyMessage = tab == .translation ? "正在翻译…" : "正在生成摘要与待办…"
            workTask = Task {
                defer { workTask = nil; busyMessage = nil }
                do {
                    let start = Date()
                    let result = try await (tab == .translation
                        ? client.translate(segments: document.segments, targetLanguage: language)
                        : client.summarize(segments: document.segments))
                    try Task.checkCancellation()
                    guard documents.first(where: { $0.id == document.id })?.segments == document.segments else {
                        errorMessage = "原文已经改变，请按当前原文重新生成。"
                        return
                    }
                    lastLatency = Date().timeIntervalSince(start)
                    updateDocument(document.id) {
                        if tab == .translation {
                            $0.translation = result; $0.translationLanguage = language
                        } else { $0.summary = result }
                    }
                } catch is CancellationError {
                } catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription; showSettings = true }
    }
    func cancelWork() {
        if workTask != nil { busyMessage = "正在取消当前任务…" }
        workTask?.cancel()
        transcriber.cancel()
        mixedSpeech.cancelTranscription()
    }
    func startMeeting() async {
        guard !isQuitting, !isStartingRecording, !isStoppingRecording,
              !recorder.isRecording, !isBusy, persistenceHealthy else { return }
        guard !translationWorkspace.isUsingSpeech else {
            errorMessage = "请先结束翻译页的语音输入，再开始会议录音。"
            return
        }
        isStartingRecording = true
        defer { isStartingRecording = false }
        player.stop()
        let source = recordingSource
        let settings = preferences
        let stamp = Date().formatted(date: .abbreviated, time: .shortened)
        let document = NoteDocument(title: "会议记录 · \(stamp)", sourceKind: .recording)
        let id = document.id
        meetingRecognitionID = id
        meetingUsesWhisper = settings.usesWhisperRecognition
        recognitionWarnings = [:]
        liveRecognitionWarning = ""
        liveRecognitionStatus = "正在启动录音…"
        isPreparingMeetingRecognition = false
        documents.insert(document, at: 0)
        liveDocumentID = id
        selection = id
        detailTab = .comparison
        liveTranslations = [:]; translationQueue = LiveTranslationQueue()
        if !translateLive { translationQueue.suspend() }
        liveTranslationStatus = ""
        translatingSegment = nil
        liveTranslationError = nil
        configureRecognitionWarnings(meetingID: id)
        recorder.onMicrophoneBuffer = { [weak self] buffer in
            guard let self, self.liveDocumentID == id else { return }
            if self.meetingUsesWhisper {
                self.microphoneMixedSpeech.append(buffer, at: self.recorder.currentMicrophoneOffset)
            } else {
                self.microphoneSpeech.append(buffer, at: self.recorder.currentMicrophoneOffset)
            }
        }
        recorder.onSystemBuffer = { [weak self] buffer in
            guard let self, self.liveDocumentID == id else { return }
            if self.meetingUsesWhisper {
                self.systemMixedSpeech.append(buffer, at: self.recorder.currentSystemOffset)
            } else {
                self.systemSpeech.append(buffer, at: self.recorder.currentSystemOffset)
            }
        }
        recorder.onError = { [weak self] error in
            guard let self, self.liveDocumentID == id else { return }
            self.errorMessage = error.localizedDescription
            if self.recorder.isRecording { Task { await self.stopMeeting() } }
        }
        do {
            // 声音采集与识别是两条独立线路。模型下载和 Apple 授权不能阻挡录音。
            try await recorder.start(in: recordingDirectory, source: source)
            persist()
            persistPreferences()
            // 启动期间退出也要保留已捕获声音，由 finishForQuit 结束并保存。
            if isQuitting { return }
            if translateLive { startTranslationLoop() }
            else { liveTranslationStatus = "实时翻译已关闭 · 录音继续保存" }
            isPreparingMeetingRecognition = true
            liveRecognitionStatus = "录音已开始，正在准备识别；准备期间的音频可在会后重新转写。"
            meetingRecognitionTask = Task { [weak self] in
                await self?.prepareMeetingRecognition(id: id, source: source, settings: settings)
            }
        } catch {
            meetingRecognitionID = nil
            meetingRecognitionTask?.cancel(); meetingRecognitionTask = nil
            isPreparingMeetingRecognition = false
            microphoneSpeech.cancel(); systemSpeech.cancel()
            microphoneMixedSpeech.cancel(); systemMixedSpeech.cancel()
            await recorder.cancel()
            if documents.first(where: { $0.id == id })?.segments.isEmpty == true {
                documents.removeAll { $0.id == id }
                selection = documents.first?.id
            }
            liveDocumentID = nil
            liveRecognitionStatus = "录音未开始"
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

    private func prepareMeetingRecognition(id: UUID, source: RecordingSource,
                                           settings: AppPreferences) async {
        defer {
            if meetingRecognitionID == id {
                isPreparingMeetingRecognition = false
                meetingRecognitionTask = nil
            }
        }
        do {
            try ensureRecognitionSession(id)
            if settings.usesWhisperRecognition {
                try await mixedSpeech.prepare(modelVariant: settings.whisperModel)
                try ensureRecognitionSession(id)
            }
            let vocabulary = settings.contextualStrings
            let update: (TranscriptSegment, Bool) -> Void = { [weak self] segment, final in
                guard let self, self.liveDocumentID == id else { return }
                self.receiveLiveSegment(segment, final: final)
            }
            if source.includesMicrophone {
                do {
                    if settings.usesWhisperRecognition {
                        try await microphoneMixedSpeech.start(
                            contextualStrings: vocabulary, source: "麦克风", locale: settings.speechLocale,
                            onUpdate: update
                        )
                    } else {
                        try await microphoneSpeech.start(
                            locale: settings.speechLocale, allowCloudRecognition: settings.allowCloudRecognition,
                            contextualStrings: vocabulary, source: "麦克风", onUpdate: update
                        )
                    }
                    try ensureRecognitionSession(id)
                } catch is CancellationError { throw CancellationError() }
                catch { recordRecognitionWarning(error, source: "麦克风", meetingID: id) }
            }
            try ensureRecognitionSession(id)
            if source.includesSystem {
                do {
                    if settings.usesWhisperRecognition {
                        try await systemMixedSpeech.start(
                            contextualStrings: vocabulary, source: "会议声音", locale: settings.speechLocale,
                            onUpdate: update
                        )
                    } else {
                        try await systemSpeech.start(
                            locale: settings.speechLocale, allowCloudRecognition: settings.allowCloudRecognition,
                            contextualStrings: vocabulary, source: "会议声音", onUpdate: update
                        )
                    }
                    try ensureRecognitionSession(id)
                } catch is CancellationError { throw CancellationError() }
                catch { recordRecognitionWarning(error, source: "会议声音", meetingID: id) }
            }
            try ensureRecognitionSession(id)
            refreshRecognitionStatus()
        } catch is CancellationError {
            if meetingRecognitionID == id, recorder.isRecording {
                refreshRecognitionStatus()
                liveRecognitionStatus += "\n未完成的识别准备已取消 · 录音继续保存"
            }
        } catch {
            recordRecognitionWarning(error, source: "识别模型", meetingID: id)
        }
    }

    private func ensureRecognitionSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard meetingRecognitionID == id, liveDocumentID == id, recorder.isRecording,
              !isStoppingRecording, !isQuitting else { throw CancellationError() }
    }

    private func configureRecognitionWarnings(meetingID: UUID) {
        microphoneMixedSpeech.onError = { [weak self] error in
            self?.recordRecognitionWarning(error, source: "麦克风", meetingID: meetingID)
        }
        systemMixedSpeech.onError = { [weak self] error in
            self?.recordRecognitionWarning(error, source: "会议声音", meetingID: meetingID)
        }
        microphoneSpeech.onError = { [weak self] error in
            self?.recordRecognitionWarning(error, source: "麦克风", meetingID: meetingID)
        }
        systemSpeech.onError = { [weak self] error in
            self?.recordRecognitionWarning(error, source: "会议声音", meetingID: meetingID)
        }
        microphoneSpeech.onStatusChange = { [weak self] _ in
            guard let self, self.meetingRecognitionID == meetingID else { return }
            self.refreshRecognitionStatus()
        }
        systemSpeech.onStatusChange = { [weak self] _ in
            guard let self, self.meetingRecognitionID == meetingID else { return }
            self.refreshRecognitionStatus()
        }
    }

    private func recordRecognitionWarning(_ error: Error, source: String, meetingID: UUID) {
        guard liveDocumentID == meetingID else { return }
        let detail: String
        if !AppleSpeechAvailability.usesAnalyzer,
           error.localizedDescription.localizedCaseInsensitiveContains("Siri and Dictation are disabled") {
            detail = "旧版 Apple 识别被系统停用。请在系统设置中开启“听写”后重新开始识别；也可结束保存后用本地 Whisper 重新转写。"
        } else { detail = error.localizedDescription }
        recognitionWarnings[source] = "\(source)：\(detail)"
        liveRecognitionWarning = "录音继续保存在本机。\n" + recognitionWarnings.keys.sorted()
            .compactMap { recognitionWarnings[$0] }.joined(separator: "\n")
        refreshRecognitionStatus()
    }

    private func refreshRecognitionStatus() {
        guard recorder.isRecording, !isStoppingRecording else { return }
        if !meetingUsesWhisper {
            var statuses: [String] = []
            if recorder.source.includesMicrophone {
                statuses.append("麦克风：\(microphoneSpeech.recognitionStatus)")
            }
            if recorder.source.includesSystem {
                statuses.append("会议声音：\(systemSpeech.recognitionStatus)")
            }
            liveRecognitionStatus = statuses.joined(separator: "\n")
            return
        }
        let microphoneActive = meetingUsesWhisper ? microphoneMixedSpeech.isRecognizing : microphoneSpeech.isRecognizing
        let systemActive = meetingUsesWhisper ? systemMixedSpeech.isRecognizing : systemSpeech.isRecognizing
        if microphoneActive || systemActive {
            liveRecognitionStatus = "\(meetingRecognitionDescription)已就绪 · 等待识别结果"
        } else {
            liveRecognitionStatus = "当前暂未转写 · 录音继续保存，可在会后重新转写。"
        }
    }
    private var meetingRecognitionDescription: String {
        guard meetingUsesWhisper else {
            return recorder.source.includesSystem
                ? systemSpeech.backendDescription + " "
                : microphoneSpeech.backendDescription + " "
        }
        switch mixedSpeech.loadedModelVariant {
        case WhisperSpeechService.defaultModelVariant: return "本地 Whisper Large v3 Turbo "
        case "small": return "本地 Whisper Small "
        default: return "本地 Whisper "
        }
    }
    func cancelMeetingRecognitionPreparation() {
        guard isPreparingMeetingRecognition else { return }
        meetingRecognitionTask?.cancel()
        if meetingUsesWhisper { mixedSpeech.cancelPreparation() }
        // 等准备任务实际退出再清状态；已经就绪的另一路识别继续工作。
        liveRecognitionStatus = "正在取消识别准备 · 录音继续保存"
    }
    private func receiveLiveSegment(_ segment: TranscriptSegment, final: Bool) {
        guard let id = liveDocumentID, let index = documents.firstIndex(where: { $0.id == id }) else { return }
        if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            documents[index].segments.removeAll { $0.id == segment.id }
            translationQueue.remove(id: segment.id)
            liveTranslations = translationQueue.translations
            persist()
            return
        }
        let status = "\(meetingRecognitionDescription)正在转写 · 原文和录音保存在本机"
        if !meetingUsesWhisper {
            refreshRecognitionStatus()
        } else if recorder.isRecording, liveRecognitionStatus != status {
            liveRecognitionStatus = status
        }
        if let existing = documents[index].segments.firstIndex(where: { $0.id == segment.id }) {
            let previous = documents[index].segments[existing]
            var updated = segment
            // 仅时间戳变化时保留译文；文字修订后立即清除，之后恢复旧文字也不复活旧结果。
            updated.translation = previous.text == segment.text ? previous.validTranslation : nil
            documents[index].segments[existing] = updated
        } else { documents[index].segments.append(segment) }
        documents[index].segments.sort { $0.start < $1.start }
        translationQueue.update(segment, isFinal: final, now: Date(),
                                requiresFinal: meetingUsesWhisper)
        // 原文更正时立即撤下旧译文；仅时间戳变化不重置文字稳定计时。
        liveTranslations = translationQueue.translations
        if final || Date().timeIntervalSince(lastPersistence) >= 5 {
            persist(); lastPersistence = Date()
        }
    }
    func setLiveTranslationEnabled(_ enabled: Bool) {
        guard translateLive != enabled else { return }
        translateLive = enabled
        liveTranslationError = nil
        if !enabled {
            liveTranslationTask?.cancel()
            liveTranslationTask = nil
            translationQueue.suspend()
            liveTranslationStatus = "实时翻译已关闭 · 录音和转写继续"
        } else {
            translationQueue.resume()
            if recorder.isRecording {
                liveTranslationStatus = "等待新的稳定语音…"
                startTranslationLoop()
            }
        }
    }
    private func startTranslationLoop() {
        liveTranslationTask?.cancel()
        liveTranslationTask = Task {
            while !Task.isCancelled && (recorder.isRecording || translationQueue.hasPending) {
                if translateLive && !isTranslatingLive {
                    // Whisper 在句末、停顿或有界句长后提交，避免反复翻译半句。
                    // Apple 识别仍使用文字稳定策略，停止时可收尾待处理结果。
                    if let segment = translationQueue.next(
                        now: Date(), flush: !recorder.isRecording && !isStoppingRecording
                    ) {
                        await translateLiveSegment(segment)
                        // 有成熟片段时接着处理，避免每次完成后再固定等待 300 ms。
                        continue
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
    private func translateLiveSegment(_ segment: TranscriptSegment) async {
        do {
            let client = try makeClient()
            let language = preferences.targetLanguage
            let configuration = preferences.configuration
            isTranslatingLive = true
            translatingSegment = segment
            defer {
                isTranslatingLive = false
                if translatingSegment?.id == segment.id { translatingSegment = nil }
            }
            liveTranslationStatus = "正在翻译…"
            let started = Date()
            let result = try await client.translate(segments: [segment], targetLanguage: language)
            try Task.checkCancellation()
            let current = documents.first { $0.id == liveDocumentID }?.segments.first { $0.id == segment.id }
            // 识别文字已被修订，旧请求不覆盖当前字幕。
            if current?.text == segment.text && preferences.targetLanguage == language &&
               preferences.configuration == configuration {
                let translation = result.replacingOccurrences(
                    of: #"^\[\d{2}:\d{2}(?::\d{2})?\]\s*(?:〔[^〕]*〕\s*)?"#,
                    with: "", options: .regularExpression
                )
                guard !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BedrockError.invalidResponse
                }
                if translationQueue.commit(translation, for: segment) {
                    liveTranslations = translationQueue.translations
                    if let id = liveDocumentID {
                        updateDocument(id) { document in
                            guard let index = document.segments.firstIndex(where: { $0.id == segment.id }),
                                  document.segments[index].text == segment.text else { return }
                            document.segments[index].translation = SegmentTranslation(
                                sourceText: segment.text, text: translation, targetLanguage: language
                            )
                        }
                    }
                }
            }
            lastLatency = Date().timeIntervalSince(started)
            liveTranslationStatus = String(format: "上次翻译 %.1f 秒", lastLatency ?? 0)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            // 停止重复的失败调用，原文和录音继续。
            setLiveTranslationEnabled(false)
            liveTranslationError = error.localizedDescription
            liveTranslationStatus = "翻译已暂停：\(error.localizedDescription)"
            translationQueue.clearPending()
        }
    }
    func stopMeeting() async {
        guard recorder.isRecording, !isStoppingRecording else { return }
        isStoppingRecording = true
        defer { isStoppingRecording = false }
        // 先隔离后台准备，不能等下载完成才允许结束，也不能晚到启动下一场会议的识别。
        meetingRecognitionID = nil
        meetingRecognitionTask?.cancel(); meetingRecognitionTask = nil
        isPreparingMeetingRecognition = false
        liveRecognitionStatus = "正在保存录音并收尾识别…"
        var recordingSaved = false
        do {
            let duration = recorder.elapsed
            let url = try await recorder.stop()
            await finishRecognition()
            if let id = liveDocumentID {
                let filename: String?
                if let url {
                    let repository = self.repository
                    filename = try await Task.detached { try repository.importMedia(from: url) }.value
                    try? FileManager.default.removeItem(at: url)
                } else { filename = nil }
                updateDocument(id) { $0.duration = duration; $0.mediaFilename = filename }
                recordingSaved = filename != nil
            }
        } catch {
            await finishRecognition()
            errorMessage = "录音结束处理失败，文字已保留。原始音频位于 \(recordingDirectory.path)。\n\(error.localizedDescription)"
            persist()
        }
        liveTranslationTask?.cancel()
        let finishedID = liveDocumentID
        if let id = finishedID {
            updateDocument(id) { document in
                // 没有实际译文时保留空状态，不能把“待翻译”提示存成成功译文。
                if document.translationContent.translatedSegments.isEmpty {
                    document.translation = ""
                } else {
                    document.translation = document.segments.compactMap { segment in
                        guard let translation = segment.validTranslation?.text else {
                            return "[\(Self.clock(segment.start))] 待翻译：结束时尚未完成，可点击“翻译全文”。"
                        }
                        return "[\(Self.clock(segment.start))] \(translation)"
                    }.joined(separator: "\n\n")
                }
                document.translationLanguage = preferences.targetLanguage
            }
        }
        liveDocumentID = nil
        liveRecognitionStatus = recordingSaved ? "录音已保存" : "录音未完成保存，请查看错误和原始音频位置。"
        translatingSegment = nil
        detailTab = .comparison
        workspaceTab = .notes
        showRecording = false
        if let document = documents.first(where: { $0.id == finishedID }) { select(document) }
    }
    private func finishRecognition() async {
        if meetingUsesWhisper {
            async let microphoneFinished: Void = microphoneMixedSpeech.finish()
            async let systemFinished: Void = systemMixedSpeech.finish()
            _ = await (microphoneFinished, systemFinished)
        } else {
            async let microphoneFinished: Void = microphoneSpeech.finish()
            async let systemFinished: Void = systemSpeech.finish()
            _ = await (microphoneFinished, systemFinished)
        }
    }
    func exportSelected(_ format: String) {
        guard let document = selectedDocument else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.title.replacingOccurrences(of: "/", with: "-") + "." + format
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .data]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data: Data
                    switch format {
                    case "srt": data = Data(TranscriptExporter.srt(document).utf8)
                    case "md": data = Data(TranscriptExporter.markdown(document).utf8)
                    case "json": data = try TranscriptExporter.json(document)
                    default: data = Data(TranscriptExporter.text(document).utf8)
                    }
                    try data.write(to: url, options: .atomic)
                } catch { self?.errorMessage = error.localizedDescription }
            }
        }
    }
    func prepareToQuit() {
        workTask?.cancel(); liveTranslationTask?.cancel()
        meetingRecognitionID = nil
        meetingRecognitionTask?.cancel(); meetingRecognitionTask = nil
        isPreparingMeetingRecognition = false
        microphoneSpeech.stop(); systemSpeech.stop()
        microphoneMixedSpeech.cancel(); systemMixedSpeech.cancel()
        mixedSpeech.cancelTranscription(); mixedSpeech.cancelPreparation()
        persist()
        persistenceQueue.sync {}
        // 原始音频持续写到 Recording；不要在退出时删除未完成的音频。
    }
    func finishForQuit() async {
        isQuitting = true
        await translationWorkspace.finishForQuit()
        mixedSpeech.cancelPreparation()
        while isStartingRecording || isStoppingRecording {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if recorder.isRecording { await stopMeeting() }
        prepareToQuit()
    }
    static func clock(_ time: Double) -> String {
        let seconds = max(0, Int(time.isFinite ? time : 0))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct AppIssue: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
#endif
