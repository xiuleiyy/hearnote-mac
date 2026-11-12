#if os(macOS)
import SwiftUI
import HearNoteCore

/// 原文和译文共用一行、一条滚动轴，长译文不会把后续片段挤到另一行。
@MainActor
struct TranscriptComparisonView: View {
    @EnvironmentObject private var state: AppState
    let documentID: UUID
    let segments: [TranscriptSegment]
    let isLive: Bool
    @State private var followsLatest = true
    private let bottomID = "transcript-comparison-bottom"

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
                HStack(spacing: 24) {
                    Label("原文", systemImage: "waveform")
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Label("翻译", systemImage: "character.bubble")
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(Palette.accent.opacity(0.06))
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if segments.isEmpty {
                            Text(isLive ? "正在聆听，原文和译文会逐段显示在两侧。" : "这份笔记还没有原文。")
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
            HStack(alignment: .top, spacing: 24) {
                Text(segment.text)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                Group {
                    if let translation = segment.validTranslation {
                        Text(translation.text).foregroundStyle(Palette.accent)
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
