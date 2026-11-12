#if os(macOS)
import AppKit
import SwiftUI

/// Attaches to the actual workspace window without replacing SwiftUI's delegate.
@MainActor
struct WindowCloseBehavior: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let onAttach: (NSWindow) -> Void
    let onOpenWindow: (OpenWindowAction) -> Void

    init(onAttach: @escaping (NSWindow) -> Void,
         onOpenWindow: @escaping (OpenWindowAction) -> Void) {
        self.onAttach = onAttach
        self.onOpenWindow = onOpenWindow
    }

    func makeNSView(context: Context) -> WorkspaceWindowAttachmentView {
        let view = WorkspaceWindowAttachmentView()
        view.onAttach = onAttach
        onOpenWindow(openWindow)
        return view
    }

    func updateNSView(_ view: WorkspaceWindowAttachmentView, context: Context) {
        view.onAttach = onAttach
        onOpenWindow(openWindow)
        view.configureWindow()
    }

    static func dismantleNSView(_ view: WorkspaceWindowAttachmentView, coordinator: ()) {
        view.onAttach = nil
    }
}

@MainActor
final class WorkspaceWindowAttachmentView: NSView {
    var onAttach: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        if let closeButton = window.standardWindowButton(.closeButton) {
            // Target the window itself so clicks remain valid across SwiftUI
            // view updates. Cmd-Q still goes through NSApplication termination.
            closeButton.target = window
            closeButton.action = #selector(NSWindow.miniaturize(_:))
        }
        onAttach?(window)
    }
}
#endif
