import Foundation

/// Read-only history boundary between the future Zia UI and conversation
/// persistence. The UI must consume THIS, never ConversationStore/SQLite
/// internals, so storage can evolve (schema, retention, sharding) without
/// touching interface code.
///
/// Phase 3 foundation only: single default conversation surfaced as one
/// bounded transcript window. Retrieval is bounded/paginated — never the
/// lifetime transcript.
@MainActor
final class HistoryService: ObservableObject {
    static let shared = HistoryService()

    /// One renderable conversation turn for the UI.
    struct HistoryTurn: Identifiable, Equatable, Sendable {
        let id: String
        let isFromUser: Bool
        let text: String
        let timestamp: Date
    }

    /// Conversation metadata for a future multi-conversation list view.
    struct ConversationSummary: Identifiable, Equatable, Sendable {
        let id: String
        let messageCount: Int
    }

    /// Currently loaded transcript window (oldest → newest).
    @Published private(set) var turns: [HistoryTurn] = []

    /// True while an older page is loading.
    @Published private(set) var isLoadingOlder = false

    /// Page size for pagination; small by design — the UI shows a window, not
    /// the lifetime transcript.
    var pageSize = 50

    /// Conversation currently surfaced by the window; paging and refresh stay
    /// within it so multi-conversation support later cannot mix transcripts.
    private var activeConversationID = "default"

    private init() {}

    /// Load the newest page for the default conversation.
    func loadRecent() {
        activeConversationID = "default"
        let messages = ConversationStore.shared.loadMessages(limit: pageSize)
        turns = messages.map(Self.turn(from:))
    }

    /// Load the full message list for one conversation ID (single page,
    /// bounded — callers pass a limit; default keeps the UI window bounded).
    func loadConversation(id: String, limit: Int = 200) {
        activeConversationID = id
        let messages = ConversationStore.shared.loadMessages(conversationId: id, limit: limit)
        turns = messages.map(Self.turn(from:))
    }

    /// Page one window further BACK in history (older messages prepended in
    /// chronological order). Returns false when no older messages exist.
    @discardableResult
    func loadOlder() -> Bool {
        guard !isLoadingOlder else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let older = ConversationStore.shared.loadMessages(conversationId: activeConversationID, limit: pageSize, offset: turns.count)
        guard !older.isEmpty else { return false }
        let olderTurns = older.map(Self.turn(from:))
        turns = olderTurns + turns
        return true
    }

    /// Refresh after a new interaction landed (keeps the current window bound).
    func refresh() {
        loadRecent()
    }

    /// Test hook: seed the transcript window without touching the default
    /// conversation other tests write to. Exposed for SelfTest only.
    func _loadWindowForTest(conversationId: String, limit: Int) {
        loadConversation(id: conversationId, limit: limit)
    }

    /// Convenience for previews/tests.
    static func turn(from message: Message) -> HistoryTurn {
        HistoryTurn(
            id: message.id,
            isFromUser: message.role == .user,
            text: message.content,
            timestamp: message.timestamp)
    }
}
