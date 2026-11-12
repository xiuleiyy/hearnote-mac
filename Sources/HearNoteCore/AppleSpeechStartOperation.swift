import Foundation

/// 系统模型下载可能共享且不立即响应 Task.cancel；取消本 App 的等待必须立即完成。
/// 底层任务晚到只结束自己的 continuation，不得重新启动当前识别或修改 UI。
@MainActor
public final class AppleSpeechStartOperation {
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: Task<Void, Never>?
    private var completed = false
    private let cancellation: () -> Void

    public init(onCancel: @escaping () -> Void) { cancellation = onCancel }

    public func run(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !completed, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                task = Task { @MainActor [weak self] in
                    do {
                        try Task.checkCancellation()
                        try await operation()
                        self?.resolve(error: nil)
                    } catch {
                        self?.resolve(error: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    public func cancel() {
        guard !completed else { return }
        task?.cancel()
        cancellation()
        resolve(error: CancellationError())
    }

    private func resolve(error: Error?) {
        guard !completed else { return }
        completed = true
        task = nil
        let continuation = continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}
