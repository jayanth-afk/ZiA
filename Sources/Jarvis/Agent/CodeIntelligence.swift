import Foundation

/// A named definition found by deterministic text analysis.
struct CodeSymbol: Sendable, Equatable {
    let name: String
    let kind: String
    let file: String
    let line: Int
}

/// A marker comment (TODO/FIXME/…) found in source.
struct CodeMarker: Sendable, Equatable {
    let marker: String
    let file: String
    let line: Int
    let text: String
}

/// Deterministic code intelligence over a directory tree.
///
/// This is text analysis, not compilation: it is fast, bounded, offline, and
/// structural enough to answer "where is X defined?" and "what is unfinished?".
/// It never executes project code and never reads sensitive locations.
enum CodeIntelligence {
    /// Source-ish extensions worth scanning. Keeps the scan fast and bounded.
    static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "py",
        "js", "jsx", "ts", "tsx", "java", "kt", "kts", "rb", "sh", "bash", "zsh",
        "css", "html", "json", "yml", "yaml", "toml", "md", "sql"
    ]

    static let definitionPattern = try? NSRegularExpression(
        pattern: "\\b(func|function|def|class|struct|enum|protocol|interface|trait|impl|actor|typealias|extension)\\s+([A-Za-z_][A-Za-z0-9_]*)",
        options: [])

    static let defaultMarkers = ["TODO", "FIXME", "HACK", "XXX"]

    /// Find definitions whose name contains `name` (case-insensitive). Empty
    /// `name` lists definitions up to the bound.
    static func findSymbols(root: String, name: String = "", maxResults: Int = 50) -> [CodeSymbol] {
        guard let regex = definitionPattern else { return [] }
        let needle = name.lowercased()
        var results: [CodeSymbol] = []

        enumerateSourceFiles(root: root) { url, lines in
            if results.count >= maxResults { return false }
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard let match = regex.firstMatch(in: line, options: [], range: range),
                      match.numberOfRanges >= 3,
                      let kindRange = Range(match.range(at: 1), in: line),
                      let nameRange = Range(match.range(at: 2), in: line) else { continue }
                let symbolName = String(line[nameRange])
                if needle.isEmpty || symbolName.lowercased().contains(needle) {
                    results.append(CodeSymbol(name: symbolName, kind: String(line[kindRange]),
                                              file: url.path, line: index + 1))
                    if results.count >= maxResults { return false }
                }
            }
            return true
        }
        return results
    }

    /// Find unfinished-work markers.
    static func findMarkers(root: String, markers: [String] = defaultMarkers, maxResults: Int = 100) -> [CodeMarker] {
        let tokens = markers.isEmpty ? defaultMarkers : markers
        var results: [CodeMarker] = []
        enumerateSourceFiles(root: root) { url, lines in
            if results.count >= maxResults { return false }
            for (index, line) in lines.enumerated() {
                let upper = line.uppercased()
                for token in tokens where upper.contains(token.uppercased()) {
                    results.append(CodeMarker(marker: token, file: url.path, line: index + 1,
                                              text: String(line.trimmingCharacters(in: .whitespaces).prefix(200))))
                    break
                }
                if results.count >= maxResults { return false }
            }
            return true
        }
        return results
    }

    // MARK: - Internals

    /// Bounded enumeration of source files, skipping sensitive locations and
    /// binary or oversized files. The closure returns false to stop early.
    private static func enumerateSourceFiles(
        root: String,
        visitLimit: Int = 20_000,
        fileLimit: Int = 4_000,
        maxBytes: Int = 512 * 1_024,
        _ body: (URL, [String]) -> Bool
    ) {
        let expanded = (root as NSString).expandingTildeInPath
        guard !SensitivePaths.contains(expanded),
              let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: expanded),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }

        var visited = 0
        var scanned = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > visitLimit || scanned >= fileLimit { break }
            guard sourceExtensions.contains(url.pathExtension.lowercased()) else { continue }
            if SensitivePaths.contains(url.path) { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if let size = values?.fileSize, size > maxBytes { continue }
            scanned += 1
            guard let text = FileSystemObserver.shared.readText(path: url.path, maximumBytes: maxBytes),
                  !text.isEmpty,
                  !text.unicodeScalars.contains(where: { $0.value == 0 }) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if !body(url, lines) { return }
        }
    }
}
