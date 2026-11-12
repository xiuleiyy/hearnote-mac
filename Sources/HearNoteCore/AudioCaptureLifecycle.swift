import Foundation

/// A shutdown error cannot undo audio that was already written. File errors
/// remain failures in every phase; only stream errors use this classification.
public struct AudioCaptureLifecycle {
    public enum StreamErrorDisposition: Equatable {
        case recordingFailure
        case shutdownWarning
        case ignore
    }

    private enum Phase { case capturing, stopping, finished }
    private var phase: Phase = .capturing
    private var stoppingAt: TimeInterval?

    public init() {}

    public var acceptsInput: Bool { phase == .capturing }

    public mutating func beginStopping(at hostTime: TimeInterval? = nil) {
        if phase == .capturing {
            phase = .stopping
            stoppingAt = hostTime
        }
    }

    public mutating func finish() { phase = .finished }

    /// Already queued samples before Stop must survive. A buffer straddling
    /// Stop is trimmed; new samples after it cannot extend the saved recording.
    public func acceptedFrameCount(start: TimeInterval, sampleRate: Double, frames: Int) -> Int {
        guard start.isFinite, sampleRate.isFinite, sampleRate > 0, frames > 0 else { return 0 }
        switch phase {
        case .capturing:
            return frames
        case .stopping:
            guard let stoppingAt, stoppingAt.isFinite else { return 0 }
            return Int(max(0, min(Double(frames), floor((stoppingAt - start) * sampleRate))))
        case .finished:
            return 0
        }
    }

    public var streamErrorDisposition: StreamErrorDisposition {
        switch phase {
        case .capturing: return .recordingFailure
        case .stopping: return .shutdownWarning
        case .finished: return .ignore
        }
    }
}

/// Concurrent stop, cancel, and failed-start cleanup share one operation and
/// its result. Cancelling a waiter must not cancel the file flush.
@MainActor
public final class AudioCaptureStopOperation<Output> {
    private var task: Task<Output, Never>?

    public init() {}

    public func run(
        _ operation: @escaping @MainActor () async -> Output
    ) async -> Output {
        if let task { return await task.value }
        let task = Task { await operation() }
        self.task = task
        return await task.value
    }
}
