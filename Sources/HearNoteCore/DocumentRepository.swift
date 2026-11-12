import Foundation

public enum RepositoryError: LocalizedError {
    case unreadableLibrary
    case unsupportedVersion
    case invalidMediaFilename

    public var errorDescription: String? {
        switch self {
        case .unreadableLibrary: return "笔记库无法读取。原文件已保留，请先备份并检查 library.json，避免覆盖已有笔记。"
        case .unsupportedVersion: return "这个笔记库来自不同版本。原文件已保留，请使用兼容版本打开。"
        case .invalidMediaFilename: return "媒体文件名不合法。"
        }
    }
}

/// A small, local library with atomic writes. The caller serializes UI access.
/// Every write checks that an existing library can still be decoded.
public final class DocumentRepository {
    public let root: URL
    public var mediaDirectory: URL { root.appendingPathComponent("media", isDirectory: true) }
    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private struct Library: Codable {
        let schemaVersion: Int
        let documents: [NoteDocument]
    }

    public init(root: URL) {
        self.root = root
    }

    public func load() throws -> [NoteDocument] {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: libraryURL.path) else { return [] }
        return try decodeLibrary().documents
    }

    public func save(_ documents: [NoteDocument]) throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: libraryURL.path) {
            _ = try decodeLibrary()
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Store Date's reference interval exactly. ISO8601DateFormatter's
        // default encoding drops fractional seconds and breaks round trips.
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(Library(schemaVersion: 1, documents: documents))
        try data.write(to: libraryURL, options: .atomic)
    }

    public func importMedia(from url: URL) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let rawExtension = url.pathExtension.lowercased()
        let safeExtension = rawExtension.range(of: #"^[a-z0-9]{1,12}$"#, options: .regularExpression) != nil
            ? rawExtension : "media"
        let filename = "\(UUID().uuidString).\(safeExtension)"
        try fileManager.copyItem(at: url, to: mediaURL(filename: filename))
        return filename
    }

    public func mediaURL(filename: String) -> URL {
        // lastPathComponent ensures decoded library metadata cannot escape mediaDirectory.
        mediaDirectory.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
    }

    private func decodeLibrary() throws -> Library {
        let library: Library
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer()
                if let interval = try? value.decode(Double.self), interval.isFinite {
                    return Date(timeIntervalSinceReferenceDate: interval)
                }
                // Read libraries written by early builds that used ISO8601.
                let text = try value.decode(String.self)
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: text) { return date }
                formatter.formatOptions.insert(.withFractionalSeconds)
                if let date = formatter.date(from: text) { return date }
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid date.")
            }
            library = try decoder.decode(Library.self, from: Data(contentsOf: libraryURL))
        } catch {
            throw RepositoryError.unreadableLibrary
        }
        guard library.schemaVersion == 1 else { throw RepositoryError.unsupportedVersion }
        for document in library.documents {
            if let filename = document.mediaFilename,
               filename.isEmpty || filename == "." || filename == ".."
                || filename.contains("/") || filename.contains("\\") {
                throw RepositoryError.invalidMediaFilename
            }
        }
        return library
    }
}
