public enum NoteActionBlockReason: Equatable, Sendable {
    case quitting
    case startingRecording
    case stoppingRecording
    case recording
    case importing
    case processing
    case missingTranscript
    case missingMedia

    public var message: String {
        switch self {
        case .quitting:
            return "正在退出并保存，请稍候。"
        case .startingRecording:
            return "正在开始录音，请稍候。"
        case .stoppingRecording:
            return "正在结束并保存会议，请稍候。"
        case .recording:
            return "会议仍在录音，请先结束并保存；会议中可使用实时翻译。"
        case .importing:
            return "正在导入文件，请稍候。"
        case .processing:
            return "当前任务尚未完成，请等待完成或取消当前任务。"
        case .missingTranscript:
            return "还没有可处理的原文，请先转写录音或输入文字。"
        case .missingMedia:
            return "这份笔记没有可重新转写的录音或音视频文件。"
        }
    }
}

/// 按钮和执行入口共用同一个操作快照，避免界面可点击但执行时静默退出。
public struct NoteActionContext: Equatable, Sendable {
    public var isQuitting: Bool
    public var isStartingRecording: Bool
    public var isStoppingRecording: Bool
    public var isRecording: Bool
    public var isImporting: Bool
    public var isProcessing: Bool

    public init(
        isQuitting: Bool = false,
        isStartingRecording: Bool = false,
        isStoppingRecording: Bool = false,
        isRecording: Bool = false,
        isImporting: Bool = false,
        isProcessing: Bool = false
    ) {
        self.isQuitting = isQuitting
        self.isStartingRecording = isStartingRecording
        self.isStoppingRecording = isStoppingRecording
        self.isRecording = isRecording
        self.isImporting = isImporting
        self.isProcessing = isProcessing
    }

    public func aiBlockReason(hasTranscript: Bool) -> NoteActionBlockReason? {
        if let reason = currentBlockReason { return reason }
        return hasTranscript ? nil : .missingTranscript
    }

    public func transcriptionBlockReason(hasMedia: Bool) -> NoteActionBlockReason? {
        if let reason = currentBlockReason { return reason }
        return hasMedia ? nil : .missingMedia
    }

    private var currentBlockReason: NoteActionBlockReason? {
        if isQuitting { return .quitting }
        if isStartingRecording { return .startingRecording }
        if isStoppingRecording { return .stoppingRecording }
        if isRecording { return .recording }
        if isImporting { return .importing }
        if isProcessing { return .processing }
        return nil
    }
}
