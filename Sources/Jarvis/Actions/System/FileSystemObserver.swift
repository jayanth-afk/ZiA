import Foundation

/// A one-shot filesystem snapshot used only for declared postconditions.
struct FileStateObservation: Sendable, Equatable {
    let path: String
    let exists: Bool
    let isRegularFile: Bool
    let isDirectory: Bool
    let fileSize: Int64?
    let modificationDate: Date?
    let isReadable: Bool
}

/// Bounded, synchronous filesystem observation. This intentionally does not poll or watch paths.
final class FileSystemObserver: Sendable {
    static let shared = FileSystemObserver()
    private init() {}

    func observe(path: String) -> FileStateObservation {
        let expanded = (path as NSString).expandingTildeInPath
        let manager = FileManager.default
        var directory = ObjCBool(false)
        let exists = manager.fileExists(atPath: expanded, isDirectory: &directory)
        guard exists else {
            return FileStateObservation(path: expanded, exists: false, isRegularFile: false, isDirectory: false, fileSize: nil, modificationDate: nil, isReadable: false)
        }
        let attributes = try? manager.attributesOfItem(atPath: expanded)
        return FileStateObservation(
            path: expanded,
            exists: true,
            isRegularFile: !directory.boolValue,
            isDirectory: directory.boolValue,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value,
            modificationDate: attributes?[.modificationDate] as? Date,
            isReadable: manager.isReadableFile(atPath: expanded)
        )
    }

    /// Bounded UTF-8 read for declared text-file verification only.
    func readText(path: String, maximumBytes: Int = 1_048_576) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let handle = FileHandle(forReadingAtPath: expanded) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: maximumBytes)
        return String(data: data, encoding: .utf8)
    }
}
