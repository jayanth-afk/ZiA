import Foundation

/// The single source of truth for credential/sensitive locations that Zia never
/// reads, lists, searches, or mutates. Centralized so every capability shares
/// exactly one boundary instead of re-listing patterns.
enum SensitivePaths {
    /// Substrings that identify a sensitive location in a path.
    static let subpaths: [String] = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".config/gcloud",
        ".env",
        ".netrc",
        ".zsh_history",
        ".bash_history"
    ]

    /// Whether an (optionally tilde-prefixed) path lies in a sensitive location.
    static func contains(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let lower = expanded.lowercased()
        return subpaths.contains { lower.contains($0) }
    }
}
