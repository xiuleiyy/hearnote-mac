#if os(macOS)
import SwiftUI
import AppKit

@main
@MainActor
struct HearNoteApp: App {
    @NSApplicationDelegateAdaptor(HearNoteAppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        WindowGroup("听译", id: "workspace") {
            WorkspaceView()
                .environmentObject(state)
                .frame(minWidth: 900, minHeight: 600)
                .background {
                    WindowCloseBehavior(
                        onAttach: { delegate.attachWorkspaceWindow($0) },
                        onOpenWindow: { action in
                            delegate.reopenWorkspace = { action(id: "workspace") }
                        }
                    )
                    .frame(width: 0, height: 0)
                }
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
    private weak var workspaceWindow: NSWindow?
    private var isReopeningWorkspace = false
    private var reopenTimeout: Task<Void, Never>?
    var reopenWorkspace: (() -> Void)?

    func attachWorkspaceWindow(_ window: NSWindow) {
        clearPendingReopen()
        guard workspaceWindow !== window else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: nil
        )
        workspaceWindow = window
        NotificationCenter.default.addObserver(
            self, selector: #selector(workspaceWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window
        )
    }

    @objc private func workspaceWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              workspaceWindow === window else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: window
        )
        workspaceWindow = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard state?.isQuitting != true else { return false }
        if let window = workspaceWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
            return false
        }
        guard let reopenWorkspace else { return true }
        guard !isReopeningWorkspace else { return false }
        isReopeningWorkspace = true
        // WindowGroup creation is asynchronous. Repeated Dock clicks must not
        // create more windows while waiting for the attachment callback.
        reopenTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearPendingReopen()
        }
        reopenWorkspace()
        return false
    }

    private func clearPendingReopen() {
        reopenTimeout?.cancel()
        reopenTimeout = nil
        isReopeningWorkspace = false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        clearPendingReopen()
        state.isQuitting = true
        Task {
            await state.finishForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    deinit { NotificationCenter.default.removeObserver(self) }
}
#else
import Foundation
@main
enum HearNoteUnsupportedHost {
    static func main() {
        print("听译是 macOS App。Linux 主机仅支持 HearNoteCore 的测试。")
    }
}
#endif
