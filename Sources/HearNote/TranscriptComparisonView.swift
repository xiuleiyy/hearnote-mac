#if os(macOS)
import SwiftUI
import HearNoteCore

/// 每个片段原文在上、译文在下，共用一条滚动轴。
@MainActor
struct TranscriptComparisonView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    let documentID: UUID
    let segments: [TranscriptSegment]
    let isLive: Bool
    @State private var followsLatest = true
    private let bottomID = "transcript-comparison-bottom"
    private var translationColor: Color {
        colorScheme == .dark
            ? Color(red: 0.92, green: 0.79, blue: 0.43)
            : Color(red: 0.45, green: 0.32, blue: 0.10)
    }

    private struct ContentChange: Equatable {
        let id: UUID
        let text: String
        let translation: SegmentTranslation?
    }
    private var contentChanges: [ContentChange] {
        segments.map { ContentChange(id: $0.id, text: $0.text, translation: $0.validTranslation) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if isLive {
                    HStack(spacing: 14) {
                        Toggle("跟随最新", isOn: $followsLatest).toggleStyle(.checkbox)
                            .help("回看前关闭跟随；录音、识别和翻译会继续。")
                        if !followsLatest {
                            Text("正在回看 · 实时接收继续")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("回到最新") {
                            followsLatest = true
                            scrollToLatest(proxy)
                        }.disabled(segments.isEmpty)
                    }.font(.callout).padding(.horizontal, 20).padding(.vertical, 10)
                }
                Label(isLive ? "实时字幕" : "原文与翻译", systemImage: "text.bubble")
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Palette.accent.opacity(0.06))
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if segments.isEmpty {
                            Text("识别后逐段显示，原文在上、译文在下。")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 170)
                        }
                        ForEach(segments) { segment in
                            comparisonRow(segment).id(segment.id)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                }
                .onAppear {
                    followsLatest = isLive
                    if isLive { scrollToLatest(proxy) }
                }
                .onChange(of: contentChanges) { _, _ in
                    if isLive && followsLatest { scrollToLatest(proxy) }
                }
                .onChange(of: followsLatest) { _, enabled in
                    if isLive && enabled { scrollToLatest(proxy) }
                }
            }
        }
    }

    private func comparisonRow(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button { state.player.seek(to: segment.start) } label: {
                    Text(AppState.clock(segment.start)).monospacedDigit()
                }
                .buttonStyle(.plain)
                .disabled(isLive || state.selectedDocument?.mediaFilename == nil)
                .help(isLive ? "录音结束后可点击时间戳回听。" : "回听这一段")
                if let source = segment.source { Text(source) }
                Spacer()
                if let translation = segment.validTranslation {
                    Text(translation.targetLanguage)
                }
            }.font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text(segment.text)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Group {
                    if let translation = segment.validTranslation {
                        Text(translation.text).foregroundStyle(translationColor)
                    } else {
                        Text(state.translationStatus(documentID: documentID, segment: segment))
                            .foregroundStyle(.secondary)
                    }
                }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: isLive ? 17 : 15))
            .lineSpacing(6)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            if state.canRetryLiveTranslation(documentID: documentID, segment: segment) {
                if let message = state.liveTranslationFailureMessage(documentID: documentID, segment: segment) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Button("重试此段翻译") {
                    state.retryLiveTranslation(documentID: documentID, segment: segment)
                }
                .buttonStyle(.bordered)
                .help("使用当前 Region 和模型重试这一段；后续字幕继续接收。")
            }
            Divider().padding(.top, 8)
        }.padding(.bottom, 18)
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        // 等本次文字修订/译文更新参与布局后，再定位同一个底部标记。
        Task { @MainActor in
            await Task.yield()
            guard isLive && followsLatest else { return }
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }
}
#endif
