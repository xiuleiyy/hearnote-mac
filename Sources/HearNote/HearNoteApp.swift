#if os(macOS)
import SwiftUI
import AppKit

@main
@MainActor
struct HearNoteApp: App {
    @NSApplicationDelegateAdaptor(HearNoteAppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
                .task { delegate.state = state; state.presentSetupIfNeeded() }
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音视频或文字…") { state.workspaceTab = .notes; state.importDocument() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button(state.liveDocumentID == nil ? "开始会议录音" : "返回当前会议") {
                    state.openMeetingWorkspace()
                }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("打开翻译") { state.workspaceTab = .translation; state.showRecording = false }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { state.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class HearNoteAppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        Task {
            await state.finishForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
import Foundation
@main
enum HearNoteUnsupportedHost {
    static func main() {
        print("HearNote 是 macOS App。Linux 主机仅支持 HearNoteCore 的测试。")
    }
}
#endif
