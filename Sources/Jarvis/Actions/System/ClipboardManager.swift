import AppKit

/// Manages macOS system clipboard read, write, and clear operations.
@MainActor
final class ClipboardManager {
    static let shared = ClipboardManager()

    private let pasteboard = NSPasteboard.general

    private init() {}

    // MARK: - Public API

    /// Read text content currently on the pasteboard.
    func getClipboardText() -> String? {
        return pasteboard.string(forType: .string)
    }

    /// Set text content onto the pasteboard.
    func setClipboardText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        JarvisLogger.actions.info("Copied text to clipboard (\(text.count) chars)")
    }

    /// Clear all pasteboard contents.
    func clearClipboard() {
        pasteboard.clearContents()
        JarvisLogger.actions.info("Cleared system clipboard")
    }
}
