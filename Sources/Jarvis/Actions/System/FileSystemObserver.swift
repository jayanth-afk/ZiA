import Foundation

/// Structured snapshot of a filesystem path state.
struct FileStateObservation: Sendable, Equatable {
    let path: String
    let exists: Bool
    let isRegularFile: Bool
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    let isReadable: Bool

    init(
        path: String,
        exists: Bool,
        isRegularFile: Bool = false,
        isDirectory: Bool = false,
        fileSize: Int64? = nil,
        modificationDate: Date? = nil,
        isReadable: Bool = false
    ) {
        self.path = path
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.isDirectory = isDirectory
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isReadable = isReadable
    }

    static func nonExistent(path: String) -> FileStateObservation {
        FileStateObservation(path: path, exists: false)
    }
}

/// Deterministic, zero-overhead filesystem observer for post-action verification.
final class FileSystemObserver: Sendable {
    static let shared = FileSystemObserver()

    private init() {}

    /// Deterministically observe state of a filesystem path without polling or external services.
    func observe(path: String) -> FileStateObservation {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)

        guard exists else {
            return FileStateObservation.nonExistent(path: path)
        }

        let isDirectory = isDir.boolValue
        let isReadable = fileManager.isReadableFile(atPath: path)

        var size: Int64? = nil
        var modDate: Date? = nil

        if let attrs = try? fileManager.attributesOfItem(atPath: path) {
            size = (attrs[.size] as? NSNumber)?.int64Value
            modDate = attrs[.modificationDate] as? Date
        }

        return FileStateObservation(
            path: path,
            exists: true,
            isRegularFile: !isDirectory,
            isDirectory: isDirectory,
            fileSize: size,
            modificationDate: modDate,
            isReadable: isReadable
        )
    }

    /// Check whether a file contains expected text (bounded read, max 64KB).
    func fileContains(path: String, substring: String, maxBytes: Int = 65536) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maxBytes)
        guard let content = String(data: data, encoding: .utf8) else { return false }
        return content.contains(substring)
    }
}
