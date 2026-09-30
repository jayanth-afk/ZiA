import Foundation
import SQLite3

/// Persistent SQLite conversation store for chat history and turns.
/// Uses native libsqlite3 with thread-safe locking.
final class ConversationStore: @unchecked Sendable {
    private final class StoreSelection: @unchecked Sendable {
        let lock = NSLock()
        var testOverride: ConversationStore?
    }
    private static let selection = StoreSelection()
    private static let productionStore = ConversationStore(databaseURL: productionDatabaseURL)

    /// Production services resolve through this accessor. SelfTest installs an
    /// isolated store before any tests run, so even a broad `clearHistory()`
    /// cannot reach the user's persistent archive.
    static var shared: ConversationStore {
        selection.lock.lock()
        defer { selection.lock.unlock() }
        return selection.testOverride ?? productionStore
    }

    /// Install an in-memory SQLite database for a test scope and return the
    /// previous override for restoration. This never opens or mutates the
    /// production database. The store itself has the same locking/schema code
    /// as production, so tests still exercise SQLite behavior.
    @discardableResult
    static func beginIsolatedTesting() -> ConversationStore? {
        let isolated = ConversationStore(databaseURL: nil)
        selection.lock.lock()
        defer { selection.lock.unlock() }
        let previous = selection.testOverride
        selection.testOverride = isolated
        return previous
    }

    static func endIsolatedTesting(restoring previous: ConversationStore?) {
        selection.lock.lock()
        defer { selection.lock.unlock() }
        selection.testOverride = previous
    }

    private static var productionDatabaseURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Jarvis", isDirectory: true)
            .appendingPathComponent("conversations.sqlite")
    }

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let databaseURL: URL?
    private(set) var isPersistentStorage = false

    /// `databaseURL == nil` explicitly selects isolated in-memory SQLite.
    /// Production callers use `shared`; tests can inject a separate location.
    init(databaseURL: URL?) {
        self.databaseURL = databaseURL
        openDatabase()
        createTables()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    // MARK: - Setup

    private func openDatabase() {
        if let databaseURL {
            try? FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let dbPath = databaseURL.path
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                isPersistentStorage = true
                JarvisLogger.memory.info("Opened SQLite database at \(dbPath)")
                return
            }
            JarvisLogger.memory.error("Failed to open SQLite database at \(dbPath); falling back to memory")
        }

        // Explicit test configuration, or fallback if production storage fails.
        if sqlite3_open(":memory:", &db) == SQLITE_OK {
            isPersistentStorage = false
            JarvisLogger.memory.info("Using isolated in-memory SQLite database")
        }
    }

    private func createTables() {
        let createSQL = """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_conv ON messages(conversation_id);
        """

        lock.lock()
        defer { lock.unlock() }

        if sqlite3_exec(db, createSQL, nil, nil, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            JarvisLogger.memory.error("Failed to create tables in SQLite: \(errmsg)")
        }
    }

    // MARK: - Public API

    /// Persist a chat message to SQLite.
    func saveMessage(_ message: Message, conversationId: String = "default") {
        lock.lock()
        defer { lock.unlock() }

        let insertSQL = "INSERT OR REPLACE INTO messages (id, conversation_id, role, content, timestamp) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, message.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, conversationId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, message.role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, message.content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 5, message.timestamp.timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let errmsg = String(cString: sqlite3_errmsg(db))
            JarvisLogger.memory.error("Failed to insert message into SQLite: \(errmsg)")
        }
    }

    /// Load the most recent messages for a conversation up to a specified limit.
    /// Returns the NEWEST `limit` messages in chronological order, so a
    /// restored window always contains the latest turns. (A naive
    /// `ORDER BY timestamp ASC LIMIT ?` would return the OLDEST turns and lose
    /// everything recent after a long history.) Ordering uses `rowid`
    /// (insertion order) as the tie-break so a user+assistant turn pair written
    /// in the same instant can never be reordered.
    /// `offset` pages BACKWARD through history (0 = newest page).
    func loadMessages(conversationId: String = "default", limit: Int = 50, offset: Int = 0) -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        let querySQL = "SELECT id, role, content, timestamp FROM messages WHERE conversation_id = ? ORDER BY rowid DESC LIMIT ? OFFSET ?;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, querySQL, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, conversationId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        sqlite3_bind_int(stmt, 3, Int32(max(0, offset)))

        var messages: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0),
                  let roleCStr = sqlite3_column_text(stmt, 1),
                  let contentCStr = sqlite3_column_text(stmt, 2) else {
                continue
            }

            let idStr = String(cString: idCStr)
            let roleStr = String(cString: roleCStr)
            let content = String(cString: contentCStr)
            let timestamp = sqlite3_column_double(stmt, 3)

            let role = Message.Role(rawValue: roleStr) ?? .user
            let date = Date(timeIntervalSince1970: timestamp)

            messages.append(Message(id: idStr, role: role, content: content, timestamp: date))
        }

        // DESC selection + ASC return: newest N turns, oldest-first.
        return messages.reversed()
    }

    /// Count messages for one conversation (bounded-window diagnostics/tests).
    func messageCount(conversationId: String = "default") -> Int {
        lock.lock()
        defer { lock.unlock() }

        let countSQL = "SELECT COUNT(*) FROM messages WHERE conversation_id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, conversationId, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Distinct conversation IDs with their message counts, oldest first.
    /// (Currently the app writes everything under "default"; this keeps the
    /// store ready for multi-conversation history without schema changes.)
    func conversationSummaries() -> [(id: String, messageCount: Int)] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT conversation_id, COUNT(*) FROM messages GROUP BY conversation_id ORDER BY MIN(rowid) ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var summaries: [(id: String, messageCount: Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idCStr = sqlite3_column_text(stmt, 0) else { continue }
            summaries.append((id: String(cString: idCStr), messageCount: Int(sqlite3_column_int(stmt, 1))))
        }
        return summaries
    }

    /// Delete messages older than the cutoff date for one conversation,
    /// removing at most `limit` (oldest first) — bounded by the retention
    /// floor upstream so a single enforcement can never sweep the archive.
    /// Returns the number of rows removed.
    func deleteMessages(olderThan cutoff: Date, limit: Int, conversationId: String = "default") -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard limit > 0 else { return 0 }
        // Oldest-first selection keeps deletion deterministic regardless of
        // rowid; same-timestamp messages still differ by insertion order.
        let sql = """
        DELETE FROM messages WHERE id IN (
            SELECT id FROM messages
            WHERE conversation_id = ? AND timestamp < ?
            ORDER BY rowid ASC
            LIMIT ?
        );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, conversationId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            JarvisLogger.memory.error("Retention delete failed: \(errmsg)")
            return 0
        }
        return Int(sqlite3_changes(db))
    }

    /// Clear all messages for a specific conversation.
    func clearHistory(conversationId: String = "default") {
        lock.lock()
        defer { lock.unlock() }

        let deleteSQL = "DELETE FROM messages WHERE conversation_id = ?;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, deleteSQL, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, conversationId, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
        JarvisLogger.memory.info("Cleared conversation history for '\(conversationId)'")
    }

    /// Count total stored messages.
    var totalMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }

        let countSQL = "SELECT COUNT(*) FROM messages;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, countSQL, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
