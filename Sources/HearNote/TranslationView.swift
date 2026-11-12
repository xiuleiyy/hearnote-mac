#if os(macOS)
import SwiftUI
import HearNoteCore

@MainActor
struct TranslationView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var workspace: TranslationWorkspace
    @State private var historyExpanded = false
    @State private var firstConversationLanguage = "简体中文"
    @State private var secondConversationLanguage = "英文"

    private var voiceUnavailable: Bool {
        state.recorder.isRecording || state.isBusy || workspace.busy
    }
    private var fixedLanguages: [String] {
        BedrockClient.supportedLanguages.filter { $0 != BedrockClient.bilingualLanguage }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if workspace.mode == .text {
                    languageSelection
                    textCards
                    textActions
                } else {
                    conversationControls
                    conversationPreview
                }
                statusLine
                if let error = workspace.errorMessage {
                    errorNotice(error)
                }
                if !workspace.historyWarning.isEmpty {
                    Label {
                        Text(workspace.historyWarning)
                            .font(.callout).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.orange)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                if workspace.mode == .conversation {
                    historyContent(title: "对话记录")
                } else {
                    DisclosureGroup(isExpanded: $historyExpanded) {
                        historyContent(title: nil)
                            .padding(.top, 14)
                    } label: {
                        Label("历史与收藏", systemImage: "clock.arrow.circlepath")
                            .font(.callout.weight(.medium))
                    }
                    .padding(18)
                    .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Palette.paper)
        .onChange(of: workspace.mode) { _, _ in workspace.close() }
        .onChange(of: firstConversationLanguage) { old, current in
            if current == secondConversationLanguage { secondConversationLanguage = old }
        }
        .onChange(of: secondConversationLanguage) { old, current in
            if current == firstConversationLanguage { firstConversationLanguage = old }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("翻译").font(.system(size: 28, weight: .semibold))
                Text(workspace.mode == .text ? "输入文字，或说一句话。" : "双方轮流说话，保存每轮原文和译文。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("翻译方式", selection: $workspace.mode) {
                ForEach(TranslationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
        }
    }

    private var languageSelection: some View {
        HStack(spacing: 14) {
            Picker("原文语言", selection: $workspace.sourceLanguage) {
                ForEach(TranslationWorkspace.sourceLanguages, id: \.self) { language in
                    Text(languageName(language)).tag(language)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity)
            Button { workspace.swapLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(!workspace.canSwap || workspace.busy)
            .help("交换原文与译文语言")
            Picker("译文语言", selection: $workspace.targetLanguage) {
                ForEach(TranslationWorkspace.targetLanguages, id: \.self) { language in
                    Text(languageName(language)).tag(language)
                }
            }
            .labelsHidden().frame(maxWidth: .infinity)
        }
        .disabled(workspace.isListening || workspace.isPreparing || workspace.isFinishingVoice)
    }

    private var textCards: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("原文").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    if !workspace.inputText.isEmpty {
                        Button("清空") { workspace.clear() }
                            .buttonStyle(.plain).font(.caption)
                            .disabled(workspace.isListening || workspace.isFinishingVoice)
                    }
                }
                ZStack(alignment: .topLeading) {
                    if workspace.inputText.isEmpty {
                        Text("输入或粘贴要翻译的内容")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $workspace.inputText)
                        .font(.system(size: 20))
                        .scrollContentBackground(.hidden)
                        .disabled(workspace.isListening || workspace.isPreparing ||
                                  workspace.isFinishingVoice || workspace.isRecognizingImage)
                }
                .frame(minHeight: 180, idealHeight: 180)
                HStack {
                    Text("\(workspace.inputText.count) / 6000")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        workspace.speak(text: workspace.inputText, language: workspace.sourceLanguage)
                    } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.plain).help("朗读原文")
                        .disabled(workspace.inputText.isEmpty || workspace.isListening ||
                                  workspace.isPreparing || workspace.isFinishingVoice)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 14) {
                Text("译文").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView {
                    Text(workspace.outputText.isEmpty ? "译文会显示在这里" : workspace.outputText)
                        .font(.system(size: 22))
                        .lineSpacing(6)
                        .foregroundStyle(workspace.outputText.isEmpty ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 180, idealHeight: 180)
                outputActions
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var outputActions: some View {
        HStack(spacing: 18) {
            Button { workspace.copyOutput() } label: { Image(systemName: "doc.on.doc") }
                .help("复制译文")
            Button {
                if workspace.isSpeaking { workspace.stopSpeaking() }
                else { workspace.speak(text: workspace.outputText, language: workspace.targetLanguage) }
            } label: {
                Image(systemName: workspace.isSpeaking ? "stop.fill" : "speaker.wave.2")
            }
            .help(workspace.isSpeaking ? "停止朗读" : "朗读译文")
            Button { workspace.toggleCurrentFavorite() } label: {
                Image(systemName: workspace.currentIsFavorite ? "star.fill" : "star")
            }
            .help(workspace.currentIsFavorite ? "取消收藏" : "收藏译文")
            Spacer()
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.accent)
        .disabled(workspace.outputText.isEmpty || workspace.isListening ||
                  workspace.isPreparing || workspace.isFinishingVoice)
    }

    private var textActions: some View {
        HStack(spacing: 12) {
            if workspace.isListening {
                Button { workspace.stopVoiceAndTranslate() } label: {
                    Label("结束并翻译", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("取消录音") { workspace.cancelVoice() }.buttonStyle(.bordered)
            } else {
                Button { workspace.translate() } label: {
                    Label("翻译", systemImage: "arrow.right")
                        .frame(minWidth: 75)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(workspace.busy ||
                          workspace.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    workspace.startVoice(sourceLanguage: workspace.sourceLanguage,
                                         targetLanguage: workspace.targetLanguage)
                } label: { Label("语音", systemImage: "mic") }
                    .buttonStyle(.bordered).disabled(voiceUnavailable)
                    .help(state.recorder.isRecording ? "请先结束会议录音" : "说完后点击“结束并翻译”")
                Button { workspace.importImage() } label: {
                    Label("图片", systemImage: "photo")
                }
                .buttonStyle(.bordered).disabled(workspace.busy)
                if workspace.busy {
                    Button("取消") { workspace.cancel() }.buttonStyle(.plain)
                }
            }
            Spacer()
        }
    }

    private var conversationControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 18) {
                conversationSide(language: $firstConversationLanguage,
                                 otherLanguage: secondConversationLanguage)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                conversationSide(language: $secondConversationLanguage,
                                 otherLanguage: firstConversationLanguage)
            }
            if workspace.isListening {
                HStack(spacing: 12) {
                    Button { workspace.stopVoiceAndTranslate() } label: {
                        Label("结束并翻译", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("取消录音") { workspace.cancelVoice() }.buttonStyle(.bordered)
                }
            } else if workspace.busy {
                Button("取消") { workspace.cancel() }.buttonStyle(.plain)
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }

    private func conversationSide(language: Binding<String>, otherLanguage: String) -> some View {
        VStack(spacing: 12) {
            Picker("说话语言", selection: language) {
                ForEach(fixedLanguages, id: \.self) { choice in
                    Text(languageName(choice)).tag(choice)
                }
            }
            .labelsHidden()
            .disabled(workspace.busy)
            Button {
                workspace.startVoice(sourceLanguage: language.wrappedValue,
                                     targetLanguage: otherLanguage)
            } label: {
                Label("\(languageName(language.wrappedValue))说话", systemImage: "mic.fill")
                    .font(.system(size: 16, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(voiceUnavailable || language.wrappedValue == otherLanguage)
        }
        .frame(maxWidth: .infinity)
    }

    private var conversationPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if workspace.inputText.isEmpty && workspace.outputText.isEmpty {
                Text("点击说话，结束后查看并朗读译文。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 30)
            } else {
                Text(workspace.inputText)
                    .font(.system(size: 20)).lineSpacing(5).textSelection(.enabled)
                if !workspace.outputText.isEmpty {
                    Divider()
                    Text(workspace.outputText)
                        .font(.system(size: 23)).lineSpacing(6)
                        .foregroundStyle(Palette.accent).textSelection(.enabled)
                    outputActions
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Palette.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusLine: some View {
        HStack(spacing: 10) {
            if workspace.busy { ProgressView().controlSize(.small) }
            if !workspace.status.isEmpty {
                Text(workspace.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let latency = workspace.lastLatency {
                Text("本次翻译 \(latency, specifier: "%.2f") 秒")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("从提交文字到完整译文返回的时间")
            }
        }
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer(minLength: 8)
            Button("设置") { state.showSettings = true }.buttonStyle(.plain)
        }
        .padding(16)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func historyContent(title: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let title { Text(title).font(.headline) }
                Spacer()
                Toggle("只看收藏", isOn: $workspace.historyFavoritesOnly)
                    .toggleStyle(.switch).controlSize(.small)
                    .font(.caption).fixedSize()
            }
            if workspace.visibleEntries.isEmpty {
                Text(workspace.historyFavoritesOnly ? "收藏的译文会显示在这里。" : "完成的翻译会保存在这里。")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(workspace.visibleEntries) { entry in
                        historyRow(entry)
                    }
                }
            }
            Text("历史与收藏保存在本机。")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func historyRow(_ entry: TranslationEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { workspace.restore(entry) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("\(languageName(entry.sourceLanguage)) → \(languageName(entry.targetLanguage))")
                        Spacer()
                        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    Text(entry.sourceText).font(.callout).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.translatedText).font(.system(size: 16)).lineLimit(3)
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(workspace.isListening || workspace.isPreparing || workspace.isFinishingVoice)
            VStack(spacing: 15) {
                Button { workspace.toggleFavorite(entry) } label: {
                    Image(systemName: entry.isFavorite ? "star.fill" : "star")
                }
                .help(entry.isFavorite ? "取消收藏" : "收藏")
                Button { workspace.speak(text: entry.translatedText, language: entry.targetLanguage) } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .help("朗读译文")
                .disabled(workspace.isListening || workspace.isPreparing || workspace.isFinishingVoice)
            }
            .buttonStyle(.plain).foregroundStyle(Palette.accent)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func languageName(_ language: String) -> String {
        switch language {
        case "简体中文": return "中文"
        case "繁体中文": return "繁體中文"
        default: return language
        }
    }
}
#endif
