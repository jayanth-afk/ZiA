import Foundation

/// Detected project ecosystems. Detection uses file NAMES only (never file
/// contents), so repository content can never influence Zia's behavior — it can
/// only tell Zia which capabilities are likely useful.
enum ProjectKind: String, Codable, Sendable, CaseIterable {
    case swiftPackage
    case xcodeProject
    case node
    case python
    case rust
    case go
    case makeBased
    case gitRepository

    var displayName: String {
        switch self {
        case .swiftPackage: return "Swift package"
        case .xcodeProject: return "Xcode project"
        case .node: return "Node project"
        case .python: return "Python project"
        case .rust: return "Rust project"
        case .go: return "Go project"
        case .makeBased: return "Make-based project"
        case .gitRepository: return "Git repository"
        }
    }
}

/// A read-only profile of the project at a root path.
struct ProjectProfile: Sendable, Equatable {
    let root: String
    let kinds: [ProjectKind]
    let markers: [String]
    let suggestedBuildCommand: String?
    let suggestedTestCommand: String?
    let branch: String?
    let importantDirectories: [String]
    let entryPoints: [String]
    let documentationFiles: [String]
    let configurationFiles: [String]

    init(
        root: String,
        kinds: [ProjectKind],
        markers: [String],
        suggestedBuildCommand: String?,
        suggestedTestCommand: String?,
        branch: String? = nil,
        importantDirectories: [String] = [],
        entryPoints: [String] = [],
        documentationFiles: [String] = [],
        configurationFiles: [String] = []
    ) {
        self.root = root
        self.kinds = kinds
        self.markers = markers
        self.suggestedBuildCommand = suggestedBuildCommand
        self.suggestedTestCommand = suggestedTestCommand
        self.branch = branch
        self.importantDirectories = importantDirectories
        self.entryPoints = entryPoints
        self.documentationFiles = documentationFiles
        self.configurationFiles = configurationFiles
    }

    var isProject: Bool { !kinds.isEmpty }

    var summary: String {
        guard isProject else { return "No recognized project markers at \(root)." }
        let names = kinds.map(\.displayName).joined(separator: ", ")
        var text = "Project at \(root): \(names)"
        if let branch { text += " (branch: \(branch))" }
        text += "."
        if let build = suggestedBuildCommand { text += " Build: `\(build)`." }
        if let test = suggestedTestCommand { text += " Test: `\(test)`." }
        if !entryPoints.isEmpty { text += " Entry: \(entryPoints.joined(separator: ", "))." }
        return text
    }
}

/// Deterministic project awareness. Structurally incapable of executing code:
/// it inspects directory entries by name and returns metadata with mtime caching.
enum ProjectInspector {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (mtime: Date, profile: ProjectProfile)] = [:]

    static func inspect(root: String) -> ProjectProfile {
        let expanded = (root as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Check cache with root directory modification time
        let rootURL = URL(fileURLWithPath: expanded)
        let rootMTime = (try? rootURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()

        cacheLock.lock()
        if let cached = cache[expanded], cached.mtime >= rootMTime {
            cacheLock.unlock()
            return cached.profile
        }
        cacheLock.unlock()

        var kinds: [ProjectKind] = []
        var markers: [String] = []

        func fileExists(_ name: String) -> Bool {
            let path = (expanded as NSString).appendingPathComponent(name)
            return fm.fileExists(atPath: path)
        }

        let entries = (try? fm.contentsOfDirectory(atPath: expanded)) ?? []

        if fileExists("Package.swift") {
            kinds.append(.swiftPackage); markers.append("Package.swift")
        }
        if let xcode = entries.first(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            kinds.append(.xcodeProject); markers.append(xcode)
        }
        if fileExists("package.json") {
            kinds.append(.node); markers.append("package.json")
        }
        if fileExists("pyproject.toml") || fileExists("requirements.txt") || fileExists("setup.py") {
            kinds.append(.python)
            for marker in ["pyproject.toml", "requirements.txt", "setup.py"] where fileExists(marker) { markers.append(marker) }
        }
        if fileExists("Cargo.toml") {
            kinds.append(.rust); markers.append("Cargo.toml")
        }
        if fileExists("go.mod") {
            kinds.append(.go); markers.append("go.mod")
        }
        if fileExists("Makefile") {
            kinds.append(.makeBased); markers.append("Makefile")
        }
        if fileExists(".git") {
            kinds.append(.gitRepository); markers.append(".git")
        }

        // Branch detection from .git/HEAD
        var detectedBranch: String? = nil
        let headPath = (expanded as NSString).appendingPathComponent(".git/HEAD")
        if let headContent = try? String(contentsOfFile: headPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            if headContent.hasPrefix("ref: refs/heads/") {
                detectedBranch = String(headContent.dropFirst("ref: refs/heads/".count))
            } else if headContent.count >= 7 {
                detectedBranch = String(headContent.prefix(7))
            }
        }

        let standardDirs = ["Sources", "Tests", "src", "tests", "docs", "pkg", "lib", "include", "bin"]
        let importantDirs = standardDirs.filter { fileExists($0) }

        let docCandidates = ["README.md", "README", "ARCHITECTURE.md", "ZIA_ARCHITECTURE.md", "AGENTS.md", "CONTRIBUTING.md", "LICENSE"]
        let docs = docCandidates.filter { fileExists($0) }

        let configCandidates = ["Package.swift", "Cargo.toml", "pyproject.toml", "package.json", "tsconfig.json", "go.mod", "Makefile", "docker-compose.yml"]
        let configs = configCandidates.filter { fileExists($0) }

        let entryCandidates = ["Sources/Jarvis/App/JarvisApp.swift", "src/index.ts", "src/main.rs", "main.go", "app.py", "main.py", "index.js", "src/App.tsx"]
        let entriesFound = entryCandidates.filter { fileExists($0) }

        let profile = ProjectProfile(
            root: expanded,
            kinds: kinds,
            markers: markers,
            suggestedBuildCommand: buildCommand(for: kinds),
            suggestedTestCommand: testCommand(for: kinds),
            branch: detectedBranch,
            importantDirectories: importantDirs,
            entryPoints: entriesFound,
            documentationFiles: docs,
            configurationFiles: configs
        )

        cacheLock.lock()
        cache[expanded] = (mtime: rootMTime, profile: profile)
        cacheLock.unlock()

        return profile
    }

    /// A project is detected when any ecosystem marker is present.
    static func detect(in directory: String) -> ProjectProfile {
        inspect(root: directory)
    }

    private static func buildCommand(for kinds: [ProjectKind]) -> String? {
        if kinds.contains(.swiftPackage) { return "swift build" }
        if kinds.contains(.xcodeProject) { return "xcodebuild" }
        if kinds.contains(.rust) { return "cargo build" }
        if kinds.contains(.go) { return "go build ./..." }
        if kinds.contains(.node) { return "npm run build" }
        if kinds.contains(.makeBased) { return "make" }
        return nil
    }

    private static func testCommand(for kinds: [ProjectKind]) -> String? {
        if kinds.contains(.swiftPackage) { return "swift test" }
        if kinds.contains(.xcodeProject) { return "xcodebuild test" }
        if kinds.contains(.rust) { return "cargo test" }
        if kinds.contains(.go) { return "go test ./..." }
        if kinds.contains(.python) { return "pytest" }
        if kinds.contains(.node) { return "npm test" }
        if kinds.contains(.makeBased) { return "make test" }
        return nil
    }
}
