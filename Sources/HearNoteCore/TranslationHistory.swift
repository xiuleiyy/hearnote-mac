import Foundation

public struct TranslationEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var sourceText: String
    public var translatedText: String
    public var sourceLanguage: String
    public var targetLanguage: String
    public var modelID: String
    public var isFavorite: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sourceText: String,
        translatedText: String,
        sourceLanguage: String,
        targetLanguage: String,
        modelID: String,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.modelID = modelID
        self.isFavorite = isFavorite
    }
}

public enum TranslationHistoryError: LocalizedError, Equatable {
    case unreadableHistory
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .unreadableHistory:
            return "翻译历史无法读取。原文件已保留，请先备份并检查 translation-history.json，避免覆盖已有记录。"
        case .unsupportedVersion:
            return "这个翻译历史来自不同版本。原文件已保留，请使用兼容版本打开。"
        }
    }
}

/// 翻译历史独立于录音笔记保存，写入前检查现有文件，避免覆盖损坏或新版数据。
public struct TranslationHistoryRepository {
    public let root: URL
    private let lock = NSLock()
    private var historyURL: URL { root.appendingPathComponent("translation-history.json") }

    private struct History: Codable {
        let schemaVersion: Int
        let entries: [TranslationEntry]
    }

    public init(root: URL) {
        self.root = root
    }

    public func load() throws -> [TranslationEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return [] }
        return try decodeHistory().entries
    }

    public func save(entries: [TranslationEntry]) throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: historyURL.path) {
            _ = try decodeHistory()
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 保存精确的 Date 数值，避免收藏后重存时丢失小数秒。
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(History(schemaVersion: 1, entries: entries))
        try data.write(to: historyURL, options: .atomic)
    }

    private func decodeHistory() throws -> History {
        let history: History
        do {
            history = try JSONDecoder().decode(History.self, from: Data(contentsOf: historyURL))
        } catch {
            throw TranslationHistoryError.unreadableHistory
        }
        guard history.schemaVersion == 1 else { throw TranslationHistoryError.unsupportedVersion }
        return history
    }
}
