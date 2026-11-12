#if os(macOS)
import SwiftUI
import AVKit
import HearNoteCore

enum Palette {
    static let accent = Color(red: 0.27, green: 0.39, blue: 0.30)
    static let paper = Color(nsColor: .windowBackgroundColor)
    static let muted = Color.secondary
}

@MainActor
struct WorkspaceView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 240)
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if state.workspaceTab == .translation {
                    TranslationView(workspace: state.translationWorkspace)
                } else if let document = state.selectedDocument {
                    DocumentView(documentID: document.id)
                } else {
                    ContentUnavailableView("留住每一次好想法", systemImage: "waveform",
                                           description: Text("开始一场会议录音，或导入音视频与文字。"))
                }
                if let busy = state.busyMessage {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(busy).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        if state.canCancelWork { Button("取消") { state.cancelWork() }.buttonStyle(.plain) }
                    }.padding(14).background(.bar)
                }
            }
        }
        .tint(Palette.accent)
        .background(Palette.paper)
        .sheet(isPresented: $state.showSettings) { SettingsView().environmentObject(state) }
        .sheet(isPresented: $state.showRecording) { RecordingView().environmentObject(state) }
        .onChange(of: state.preferences.targetLanguage) { _, _ in state.persistPreferences() }
        .alert("需要处理", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { state.errorMessage = nil }
        } message: { Text(state.errorMessage ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(Palette.accent)
                Text("听记").font(.title2.weight(.semibold))
                Text("Mac").font(.caption).foregroundStyle(.tertiary)
            }.padding(.top, 25)
            HStack(spacing: 6) {
                workspaceButton("听记", systemImage: "waveform", tab: .notes)
                workspaceButton("翻译", systemImage: "character.bubble", tab: .translation)
            }
            Button { state.workspaceTab = .notes; state.showRecording = true } label: {
                Label("开始会议录音", systemImage: "mic.fill")
                    .font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).disabled(state.isBusy)
            if state.workspaceTab == .notes {
                TextField("搜索笔记", text: $state.searchText)
                    .textFieldStyle(.roundedBorder).font(.callout)
                HStack {
                    Text(state.favoritesOnly ? "收藏" : "我的笔记")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { state.favoritesOnly.toggle() } label: {
                        Image(systemName: state.favoritesOnly ? "star.fill" : "star")
                    }.buttonStyle(.plain).help("只显示收藏")
                }
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.visibleDocuments) { document in
                            Button { state.workspaceTab = .notes; state.select(document) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 7) {
                                        Image(systemName: document.sourceKind == .video ? "film" : "waveform")
                                            .foregroundStyle(.secondary)
                                        Text(document.title).lineLimit(1).font(.system(size: 13, weight: .medium))
                                        if document.isFavorite { Image(systemName: "star.fill").font(.caption2) }
                                    }
                                    HStack {
                                        Text(document.createdAt.formatted(date: .abbreviated, time: .omitted))
                                        Spacer()
                                        Text(document.sourceKind.label)
                                    }.font(.caption2).foregroundStyle(.secondary)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(state.selection == document.id ? Palette.accent.opacity(0.10) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button(document.isFavorite ? "取消收藏" : "收藏") {
                                        state.updateDocument(document.id) { $0.isFavorite.toggle() }
                                    }
                                    Button("删除笔记", role: .destructive) { state.removeDocument(document.id) }
                                        .disabled(document.id == state.liveDocumentID || state.isBusy)
                                }
                        }
                    }
                }
            } else {
                Text("文字、语音与面对面对话")
                    .font(.callout).foregroundStyle(.secondary)
                Text("图片中的文字也可以翻译。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Label("文件保存在本机", systemImage: "internaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { state.showSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Bedrock、语音与术语设置")
            }
        }.padding(.horizontal, 18).padding(.bottom, 20).background(.ultraThinMaterial)
    }
    private func workspaceButton(_ title: String, systemImage: String, tab: WorkspaceTab) -> some View {
        Button { state.workspaceTab = tab } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(state.workspaceTab == tab ? Palette.accent.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var toolbar: some View {
        HStack(spacing: 14) {
            Text(state.workspaceTab == .translation ? "翻译" : "音视频笔记")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Menu {
                ForEach(SettingsView.regions, id: \.id) { item in
                    Button(item.name) { state.selectRegion(item.id) }
                }
                Divider()
                Button("其他 Region…") { state.showSettings = true }
            } label: {
                Label(SettingsView.regionName(state.preferences.region), systemImage: "globe.asia.australia")
                    .font(.caption)
            }.menuStyle(.borderlessButton).fixedSize()
            Menu {
                ForEach(state.preferences.models) { model in
                    Button(model.name) { state.selectModel(model.modelID) }
                }
                Divider()
                Button("管理模型…") { state.showSettings = true }
            } label: {
                Label(state.activeModelName, systemImage: "sparkles").font(.caption)
            }.menuStyle(.borderlessButton).fixedSize()
            if state.workspaceTab == .notes {
                Button { state.importDocument() } label: { Label("导入", systemImage: "plus") }
                    .disabled(state.isBusy || state.recorder.isRecording)
            }
        }.padding(.horizontal, 26).padding(.vertical, 19)
    }
}

@MainActor
struct DocumentView: View {
    @EnvironmentObject private var state: AppState
    let documentID: UUID
    private var document: NoteDocument? { state.documents.first { $0.id == documentID } }
    var body: some View {
        if let document {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("笔记标题", text: Binding(
                            get: { self.document?.title ?? "" },
                            set: { value in state.updateDocument(documentID) { $0.title = value } }
                        )).textFieldStyle(.plain).font(.system(size: 25, weight: .semibold))
                        Menu {
                            Button("纯文本 .txt") { state.exportSelected("txt") }
                            Button("字幕 .srt") { state.exportSelected("srt") }
                            Button("笔记 .md") { state.exportSelected("md") }
                            Button("完整记录 .json") { state.exportSelected("json") }
                        } label: { Label("导出", systemImage: "square.and.arrow.up") }.fixedSize()
                    }
                    HStack(spacing: 13) {
                        Text(document.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text("·")
                        Text(document.sourceKind.label)
                        if document.duration > 0 { Text("·"); Text(AppState.clock(document.duration)) }
                        if document.sourceKind == .sample {
                            Text("内置示例，未调用模型").foregroundStyle(Palette.accent)
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("内容", selection: $state.detailTab) {
                            ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 290)
                        Spacer()
                        if state.detailTab == .translation {
                            Picker("目标", selection: $state.preferences.targetLanguage) {
                                ForEach(BedrockClient.supportedLanguages, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 110)
                        }
                        if state.detailTab == .translation || state.detailTab == .summary {
                            Button {
                                state.runAI(state.detailTab)
                            } label: {
                                Label(state.detailTab == .translation ? "翻译全文" : "生成摘要", systemImage: "sparkles")
                            }.disabled(state.isBusy || document.segments.isEmpty)
                        } else if state.detailTab == .transcript && document.mediaFilename != nil {
                            Button("重新转写") { state.transcribeSelected() }.disabled(state.isBusy)
                        }
                    }
                }.padding(.horizontal, 34).padding(.top, 28).padding(.bottom, 22)
                Divider()
                if state.detailTab == .comparison {
                    VStack(spacing: 0) {
                        if !document.translation.isEmpty &&
                            !document.segments.contains(where: { $0.validTranslation != nil }) {
                            Text("这份笔记的全文译文尚未逐段关联，可在“翻译”页查看。")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20).padding(.vertical, 12)
                        }
                        TranscriptComparisonView(
                            documentID: documentID, segments: document.segments,
                            isLive: state.liveDocumentID == documentID
                        ).id(documentID)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if state.detailTab == .transcript {
                                if document.segments.isEmpty {
                                    ContentUnavailableView("等待转写", systemImage: "text.bubble",
                                                           description: Text("导入后会开始转写；录音会实时显示识别结果。"))
                                } else {
                                    ForEach(document.segments) { segment in
                                        TranscriptRow(documentID: documentID, segment: segment)
                                    }
                                }
                            } else if state.detailTab == .translation {
                                if document.translation.isEmpty {
                                    emptyAI("把语言变成桥梁", "选择目标语言，然后点击“翻译全文”。")
                                } else {
                                    Text(document.translation).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
                                    Text("实时译文可能只包含已完成片段；“翻译全文”会重新处理完整原文。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else if state.detailTab == .summary {
                                if document.summary.isEmpty {
                                    emptyAI("从对话里找到重点", "生成带时间戳的重点、决定与待办。")
                                } else {
                                    MarkdownText(text: document.summary)
                                }
                            }
                        }.padding(34).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if document.mediaFilename != nil { PlayerView(player: state.player) }
            }
            .onAppear { state.select(document) }
        }
    }
    private func emptyAI(_ title: String, _ description: String) -> some View {
        ContentUnavailableView(title, systemImage: "sparkles", description: Text(description))
            .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

@MainActor
struct TranscriptRow: View {
    @EnvironmentObject private var state: AppState
    let documentID: UUID
    let segment: TranscriptSegment
    var body: some View {
        HStack(alignment: .top, spacing: 19) {
            Button { state.player.seek(to: segment.start) } label: {
                Text(AppState.clock(segment.start)).monospacedDigit().font(.caption)
                    .foregroundStyle(Palette.accent).padding(.vertical, 6).padding(.horizontal, 8)
                    .background(Palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 7) {
                if let source = segment.source {
                    Text(source).font(.caption2).foregroundStyle(.secondary)
                }
                TextField("文字", text: Binding(
                    get: { state.documents.first { $0.id == documentID }?.segments.first { $0.id == segment.id }?.text ?? "" },
                    set: { state.updateText(documentID: documentID, segmentID: segment.id, text: $0) }
                ), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 15)).lineSpacing(6)
                .disabled(state.isBusy || state.liveDocumentID == documentID)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct PlayerView: View {
    @ObservedObject var player: MediaPlayer
    @State private var rate: Float = 1
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 15) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13)).frame(width: 30, height: 30)
                }.buttonStyle(.borderless)
                Text(AppState.clock(player.currentTime)).font(.caption).monospacedDigit()
                Slider(value: Binding(get: { min(player.currentTime, max(0, player.duration)) },
                                      set: { player.seek(to: $0) }),
                       in: 0...max(1, player.duration))
                Text(AppState.clock(player.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Picker("倍速", selection: $rate) {
                    Text("0.75×").tag(Float(0.75)); Text("1×").tag(Float(1))
                    Text("1.25×").tag(Float(1.25)); Text("1.5×").tag(Float(1.5))
                }.frame(width: 85).labelsHidden().onChange(of: rate) { _, value in player.setRate(value) }
            }.padding(.horizontal, 28).padding(.vertical, 17)
        }.background(.bar)
    }
}

@MainActor
struct MarkdownText: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 12)
                } else if line.hasPrefix("# ") {
                    Text(String(line.dropFirst(2))).font(.title2.weight(.semibold))
                } else if !line.isEmpty {
                    Text((try? AttributedString(markdown: line)) ?? AttributedString(line))
                        .font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct RecordingView: View {
    @EnvironmentObject private var state: AppState
    @State private var recorderIsRecording = false
    private var meetingIsActive: Bool {
        state.liveDocumentID != nil || recorderIsRecording || state.isStoppingRecording
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Palette.accent)
                Text(state.isStoppingRecording ? "正在保存会议" :
                        (meetingIsActive ? "正在记录会议" : "开始会议录音"))
                    .font(.title2.weight(.semibold))
                Spacer()
                if meetingIsActive {
                    RecordingTimerView(recorder: state.recorder)
                } else {
                    Button { state.showRecording = false } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).disabled(state.isStartingRecording)
                }
            }
            if !meetingIsActive {
                Picker("录音来源", selection: $state.recordingSource) {
                    ForEach(RecordingSource.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(state.isStartingRecording)
                Text(state.recordingSource == .microphone
                     ? "录制麦克风收到的声音。"
                     : "录制 Zoom、飞书等软件播放的系统声音。首次使用需授予系统录制权限；其他软件的提示音也可能被录入。")
                    .font(.callout).foregroundStyle(.secondary).lineSpacing(5)
            }
            languageControls
            if !meetingIsActive {
                SpeechRecognitionEnginePicker(
                    selection: $state.preferences.speechEngine,
                    speechLocale: state.preferences.speechLocale,
                    isLocked: state.isStartingRecording
                )
                Text("中英混合在中文／英文之间识别；English 固定英文，适合全英文会议。翻译方向由“翻译为”单独设置。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }
            if state.preferences.targetLanguage == BedrockClient.bilingualLanguage {
                Text("中文 → 英文 · English → 中文；同句混用时保留专业术语。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !meetingIsActive && state.preferences.usesWhisperRecognition {
                MixedSpeechModelControls(
                    service: state.mixedSpeech, modelVariant: $state.preferences.whisperModel,
                    isLocked: {
                        meetingIsActive || state.isBusy || state.isQuitting ||
                            state.translationWorkspace.isUsingSpeech
                    }
                )
            }
            modelControls
            if meetingIsActive {
                RecordingAudioStatusView(recorder: state.recorder)
                if state.isPreparingMeetingRecognition {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top, spacing: 12) {
                            if state.preferences.usesWhisperRecognition {
                                WhisperPreparationStatusView(service: state.mixedSpeech)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text("正在准备 Apple 语音识别…")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button("取消准备") { state.cancelMeetingRecognitionPreparation() }
                                .disabled(state.isStoppingRecording)
                        }
                        Text("录音继续保存；模型就绪后识别新声音，准备期间的音频可在会后重新转写。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(state.liveRecognitionStatus.isEmpty ? "等待识别状态…" : state.liveRecognitionStatus)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .help(state.liveRecognitionStatus)
                if !state.liveRecognitionWarning.isEmpty {
                    ScrollView {
                        Text(state.liveRecognitionWarning).font(.caption).foregroundStyle(.orange)
                            .lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 48)
                }
                if let document = state.documents.first(where: { $0.id == state.liveDocumentID }) {
                    TranscriptComparisonView(documentID: document.id, segments: document.segments, isLive: true)
                        .id(document.id)
                        .background(Palette.accent.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(minHeight: 180, maxHeight: .infinity)
                } else {
                    Text("正在准备会议记录…").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 230)
                }
                Text(state.liveTranslationStatus.isEmpty ? "录音和文字保存在本机" : state.liveTranslationStatus)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).help(state.liveTranslationStatus)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("左侧原文、右侧译文，逐段实时对照", systemImage: "rectangle.split.2x1")
                    Label("录音和文字保存在这台 Mac", systemImage: "internaldrive")
                    Label("翻译使用所选 Bedrock Region 与模型", systemImage: "sparkles")
                }.font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            }
            recordingActions.layoutPriority(1)
        }
        .padding(24).frame(width: 900).frame(height: meetingIsActive ? 720 : nil)
        .frame(minHeight: 380)
        .tint(Palette.accent)
        .interactiveDismissDisabled(meetingIsActive || state.isStartingRecording || state.isStoppingRecording)
        // 不订阅 recorder 的计时/电平更新；只有录音阶段变化影响完整界面。
        .onReceive(state.recorder.$isRecording) { recorderIsRecording = $0 }
    }

    private var languageControls: some View {
        HStack {
            Picker("会议语言", selection: $state.preferences.speechLocale) {
                Text("中英混合").tag("zh-en")
                Text("普通话").tag("zh-CN"); Text("English").tag("en-US")
                Text("日本語").tag("ja-JP"); Text("한국어").tag("ko-KR")
            }.frame(width: 175).disabled(meetingIsActive || state.isStartingRecording)
            Spacer()
            Toggle("实时翻译", isOn: Binding(
                get: { state.translateLive },
                set: { state.setLiveTranslationEnabled($0) }
            )).toggleStyle(.switch).disabled(state.isStartingRecording || state.isStoppingRecording)
            Picker("翻译为", selection: $state.preferences.targetLanguage) {
                ForEach(BedrockClient.supportedLanguages, id: \.self) { Text($0).tag($0) }
            }.frame(width: 150).disabled(meetingIsActive || state.isStartingRecording)
        }
    }

    private var modelControls: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(SettingsView.regions, id: \.id) { region in
                    Button(region.name) { state.selectRegion(region.id) }
                }
            } label: {
                Label(SettingsView.regionName(state.preferences.region), systemImage: "globe.asia.australia")
            }
            Menu {
                ForEach(state.preferences.models) { model in
                    Button(model.name) { state.selectModel(model.modelID) }
                }
            } label: { Label(state.activeModelName, systemImage: "sparkles") }
            Spacer()
            Text("可切换，下一次翻译使用新选择").font(.caption).foregroundStyle(.secondary)
        }.font(.caption).disabled(state.isStartingRecording || state.isStoppingRecording)
    }

    private var recordingActions: some View {
        HStack {
            if !meetingIsActive {
                Text("可以戴耳机，减少麦克风重复收录会议声音。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.isStartingRecording || state.isStoppingRecording {
                ProgressView().controlSize(.small)
                Text(state.isStartingRecording ? "正在开始录音…" : "正在保存…").font(.callout)
            } else if recorderIsRecording {
                Button { Task { await state.stopMeeting() } } label: {
                    Label("结束并保存", systemImage: "stop.fill")
                }.buttonStyle(.borderedProminent)
            } else {
                Button { Task { await state.startMeeting() } } label: {
                    Label("开始录音", systemImage: "mic.fill")
                }.buttonStyle(.borderedProminent)
            }
        }
    }
}

@MainActor
private struct RecordingAudioStatusView: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        HStack(spacing: 20) {
            if recorder.source.includesMicrophone {
                sourceStatus("麦克风", duration: recorder.microphoneAudioDuration,
                             level: recorder.microphoneAudioLevel)
            }
            if recorder.source.includesSystem {
                sourceStatus("系统声音", duration: recorder.systemAudioDuration,
                             level: recorder.systemAudioLevel)
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func sourceStatus(_ title: String, duration: Double, level: Double) -> some View {
        HStack(spacing: 7) {
            Image(systemName: level > 0.005 ? "waveform" : "speaker.wave.1")
                .foregroundStyle(level > 0.005 ? Palette.accent : Color.secondary)
            Text(duration > 0
                 ? "\(title) · 已收到音频 \(AppState.clock(duration))"
                 : "\(title) · 等待音频")
                .monospacedDigit()
            Text(level > 0.005 ? "当前有声音" : "当前电平较低")
        }
        .help(duration > 0
              ? "已收到音频数据，是否包含可识别的说话内容以转写结果为准。"
              : "尚未收到音频。请检查录音来源、系统录制权限和会议软件的声音输出。")
    }
}

@MainActor
private struct RecordingTimerView: View {
    @ObservedObject var recorder: MeetingRecorder
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(recorder.isRecording ? Color.red : Color.secondary).frame(width: 7, height: 7)
            Text(AppState.clock(recorder.elapsed)).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
#endif
