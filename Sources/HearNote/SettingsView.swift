#if os(macOS)
import SwiftUI
import AppKit
import HearNoteCore

struct RegionChoice {
    let id: String
    let name: String
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = AppPreferences()
    @State private var apiKey = ""
    @State private var newModelName = ""
    @State private var newModelID = ""
    @State private var status = ""
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var hasSavedKey = false
    static let regions = [
        RegionChoice(id: "ap-northeast-1", name: "东京"),
        RegionChoice(id: "ap-southeast-1", name: "新加坡"),
        RegionChoice(id: "us-east-1", name: "美国东部"),
        RegionChoice(id: "us-west-2", name: "美国西部"),
        RegionChoice(id: "eu-west-1", name: "爱尔兰")
    ]
    static func regionName(_ id: String) -> String { regions.first { $0.id == id }?.name ?? id }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(draft.hasCompletedSetup ? "设置" : "让听译连接你的 Bedrock")
                        .font(.title2.weight(.semibold))
                    Text("填入 Bedrock API Key 后测试连接。区域和模型已预选，可随时调整。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 23) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text("API Key").frame(width: 75, alignment: .leading)
                                SecureField(hasSavedKey ? "已保存；留空保留，输入可替换" : "粘贴 Bedrock API Key", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("Region").frame(width: 75, alignment: .leading)
                                TextField("ap-northeast-1", text: $draft.region).textFieldStyle(.roundedBorder)
                                Menu("选择区域") {
                                    ForEach(Self.regions, id: \.id) { item in
                                        Button("\(item.name) · \(item.id)") { draft.region = item.id }
                                    }
                                }.fixedSize()
                            }
                            HStack {
                                Text("模型").frame(width: 75, alignment: .leading)
                                Picker("模型", selection: $draft.modelID) {
                                    Text("请选择或添加模型").tag("")
                                    ForEach(draft.models) { Text($0.name).tag($0.modelID) }
                                }.labelsHidden()
                            }
                            DisclosureGroup("添加或管理模型") {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        TextField("显示名称", text: $newModelName).textFieldStyle(.roundedBorder).frame(width: 140)
                                        TextField("完整模型 ID / inference profile ID", text: $newModelID)
                                            .textFieldStyle(.roundedBorder)
                                        Button("添加") { addModel() }.disabled(newModelID.trimmingCharacters(in: .whitespaces).isEmpty)
                                    }
                                    ForEach(draft.models) { model in
                                        HStack {
                                            Text(model.modelID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                            Spacer()
                                            Button { removeModel(model) } label: { Image(systemName: "minus.circle") }
                                                .buttonStyle(.plain).help("从本地列表移除")
                                        }
                                    }
                                    Text("模型 ID 从你的 Bedrock 控制台复制。模型须支持文本 Converse；区域与模型是否可用，以测试结果为准。")
                                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                                }
                                .padding(.top, 10)
                            }
                            HStack {
                                Button("测试连接") { testConnection() }.disabled(testing || !draft.configuration.isConfigured)
                                if testing { ProgressView().controlSize(.small) }
                                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                Spacer()
                            }
                            Text("API Key 保存在 Mac 钥匙串。翻译和摘要会将对应文字发送给 Bedrock，使用所选模型处理。连接测试会发起一次短模型调用。")
                                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                        }.padding(12)
                    } label: { Label("Bedrock", systemImage: "sparkles") }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Text("识别语言")
                                Spacer()
                                Picker("识别语言", selection: $draft.speechLocale) {
                                    Text("中英混合").tag("zh-en")
                                    Text("普通话").tag("zh-CN"); Text("English").tag("en-US")
                                    Text("日本語").tag("ja-JP"); Text("한국어").tag("ko-KR")
                                }.labelsHidden().frame(width: 180)
                            }
                            SpeechRecognitionEnginePicker(
                                selection: $draft.speechEngine, speechLocale: draft.speechLocale
                            )
                            Text("中英混合在中文／英文之间识别；English 固定英文，适合全英文会议。识别语言与翻译方向独立设置。")
                                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                            if draft.usesWhisperRecognition {
                                MixedSpeechModelControls(
                                    service: state.mixedSpeech, modelVariant: $draft.whisperModel,
                                    isLocked: {
                                        state.recorder.isRecording || state.isBusy || state.isQuitting ||
                                            state.translationWorkspace.isUsingSpeech
                                    }
                                )
                            } else {
                                if AppleSpeechAvailability.usesAnalyzer {
                                    Text("使用 macOS 的 Apple 本地识别，无需开启 Siri／听写。首次使用某种语言时，系统可能需要下载识别资源；准备进度会显示在会议中。语音在这台 Mac 处理。")
                                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                                } else {
                                    Toggle("允许 Apple 联网语音识别", isOn: $draft.allowCloudRecognition)
                                    Text("旧版 Apple 识别依赖 macOS 的 Siri／听写设置。开启联网选项后，音频可能交给 Apple 识别。macOS 26 配合新版编译工具可使用新的本地识别。")
                                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                                }
                            }
                            Text("常用专有词（每行一个）").font(.caption.weight(.medium))
                            TextEditor(text: $draft.vocabulary).font(.callout).frame(height: 65)
                                .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            Text("翻译术语表（每行：原词=译法）").font(.caption.weight(.medium))
                            TextEditor(text: $draft.glossary).font(.callout).frame(height: 65)
                                .padding(5).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }.padding(12)
                    } label: { Label("语音与准确性", systemImage: "waveform") }
                }
            }
            HStack {
                if !draft.hasCompletedSetup {
                    Button("暂时跳过") {
                        state.preferences.hasCompletedSetup = true
                        state.persistPreferences()
                        close()
                    }
                } else if hasSavedKey {
                    Button("移除 API Key", role: .destructive) {
                        do {
                            state.translationWorkspace.configurationChanged()
                            try KeychainStore.deleteAPIKey()
                            hasSavedKey = false; apiKey = ""; status = "API Key 已移除。"
                        }
                        catch { status = error.localizedDescription }
                    }
                }
                Spacer()
                Button("保存并继续") { save() }.buttonStyle(.borderedProminent).tint(Palette.actionFill)
                    .disabled(testing || state.recorder.isRecording)
            }
        }.padding(28).frame(width: 700, height: 720).tint(Palette.accent)
            .onAppear {
                draft = state.preferences
                hasSavedKey = (try? KeychainStore.loadAPIKey()) != nil
            }
            .onDisappear { testTask?.cancel(); apiKey = "" }
    }
    private func addModel() {
        let id = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = newModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BedrockConfiguration(region: draft.region, modelID: id).isConfigured else {
            status = "请填写合法的 Region 和完整模型 ID。"; return
        }
        if !draft.models.contains(where: { $0.modelID == id }) {
            draft.models.append(SavedModel(name: name.isEmpty ? id : name, modelID: id))
        }
        draft.modelID = id; newModelName = ""; newModelID = ""
    }
    private func removeModel(_ model: SavedModel) {
        draft.models.removeAll { $0.id == model.id }
        if draft.modelID == model.id { draft.modelID = draft.models.first?.modelID ?? "" }
    }
    private func testConnection() {
        testing = true; status = ""
        testTask = Task {
            defer { testing = false }
            do {
                let entered = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                let client = try state.makeClient(preferences: draft, key: entered.isEmpty ? nil : entered)
                let started = Date()
                _ = try await client.testConnection()
                try Task.checkCancellation()
                status = String(format: "连接成功 · 总耗时 %.2f 秒", Date().timeIntervalSince(started))
            } catch is CancellationError {
            } catch { status = error.localizedDescription }
        }
    }
    private func save() {
        do {
            try state.savePreferences(draft, apiKey: apiKey)
            close()
        } catch { status = error.localizedDescription }
    }
    private func close() {
        testTask?.cancel(); apiKey = ""; state.showSettings = false
    }
}

@MainActor
struct SpeechRecognitionEnginePicker: View {
    @Binding var selection: SpeechRecognitionEngine
    let speechLocale: String
    var isLocked = false

    private var effectiveSelection: Binding<SpeechRecognitionEngine> {
        Binding(
            get: { speechLocale == "zh-en" ? .whisper : selection },
            set: { selection = $0 }
        )
    }

    var body: some View {
        HStack {
            Text("识别方式")
            Spacer()
            Picker("识别方式", selection: effectiveSelection) {
                Text("本地 Whisper").tag(SpeechRecognitionEngine.whisper)
                Text(AppleSpeechAvailability.usesAnalyzer ? "Apple 本地识别" : "Apple 语音识别")
                    .tag(SpeechRecognitionEngine.apple)
            }
            .labelsHidden().frame(width: 200)
            .disabled(isLocked || speechLocale == "zh-en")
            .help(speechLocale == "zh-en"
                  ? "中英混合使用本地 Whisper，在中文和英文之间识别。"
                  : (AppleSpeechAvailability.usesAnalyzer
                     ? "Apple 本地识别无需开启 Siri／听写；首次使用可能需要准备语言资源。"
                     : "旧版 Apple 识别需要开启系统听写；本地 Whisper 无此依赖。"))
        }
    }
}

@MainActor
struct WhisperPreparationStatusView: View {
    @ObservedObject var service: WhisperSpeechService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if service.isPreparing && service.preparationProgress == nil {
                    ProgressView().controlSize(.small)
                }
                Text(service.modelStatus.isEmpty ? "正在准备本地识别模型…" : service.modelStatus)
                    .lineLimit(2).help(service.modelStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if service.isPreparing || service.preparationElapsed > 0 {
                    Text("已用 \(AppState.clock(service.preparationElapsed))")
                        .monospacedDigit().fixedSize()
                }
            }
            if service.isPreparing, let progress = service.preparationProgress {
                HStack(spacing: 10) {
                    ProgressView(value: progress, total: 1)
                    Text("\(Int((progress * 100).rounded()))%")
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                .help("文件准备进度；模型初始化和编译会显示各自的阶段。")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

@MainActor
struct MixedSpeechModelControls: View {
    @ObservedObject var service: WhisperSpeechService
    @Binding var modelVariant: String
    var isLocked: () -> Bool = { false }
    @State private var preparation: Task<Void, Never>?
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("本地识别模型", selection: $modelVariant) {
                    Text("Whisper Large v3 Turbo").tag("large-v3-v20240930_turbo")
                    Text("Whisper Small").tag("small")
                }.disabled(isLocked() || service.isPreparing)
                Spacer()
                if service.isPreparing {
                    Button("取消准备") {
                        preparation?.cancel()
                        service.cancelPreparation()
                    }
                } else {
                    Button("准备模型") { prepare() }.disabled(isLocked())
                    Button("导入本地模型…") { importModel() }.disabled(isLocked())
                }
            }
            Text("首次使用需下载本地语音模型，之后复用。可提前准备；下载不便时可导入完整模型目录。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            if service.isPreparing || !service.modelStatus.isEmpty {
                WhisperPreparationStatusView(service: service)
            }
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.orange).lineSpacing(4)
            }
        }
    }
    private func prepare() {
        guard !isLocked() else {
            errorMessage = "请先结束语音输入、会议录音或文件处理，再准备模型。"
            return
        }
        let selected = modelVariant
        errorMessage = ""
        preparation = Task {
            guard !isLocked() else {
                errorMessage = "语音输入或录音已经开始，请结束后再准备模型。"
                return
            }
            do { try await service.prepare(modelVariant: selected) }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }
    private func importModel() {
        guard !isLocked() else {
            errorMessage = "请先结束语音输入、会议录音或文件处理，再导入模型。"
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 CoreML 模型和 tokenizer 文件的完整 WhisperKit 模型目录。"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard !isLocked() else {
                    errorMessage = "语音输入或录音已经开始，请结束后再导入模型。"
                    return
                }
                let selected = modelVariant
                errorMessage = ""
                preparation = Task {
                    guard !isLocked() else {
                        errorMessage = "语音输入或录音已经开始，请结束后再导入模型。"
                        return
                    }
                    do { try await service.useLocalModelDirectory(url, modelVariant: selected) }
                    catch is CancellationError {}
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }
}
#endif
