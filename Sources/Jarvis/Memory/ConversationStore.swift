import Foundation
import SQLite3

/// Persistent SQLite conversation store for chat history and turns.
/// Uses native libsqlite3 with thread-safe locking.
final class ConversationStore: @unchecked Sendable {
    static let shared = ConversationStore()

    private let lock = NSLock()
    private var db: OpaquePointer?

    private init() {
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let jarvisDir = appSupport?.appendingPathComponent("Jarvis")

        if let jarvisDir = jarvisDir {
            try? FileManager.default.createDirectory(at: jarvisDir, withIntermediateDirectories: true)
            let dbPath = jarvisDir.appendingPathComponent("conversations.sqlite").path
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                JarvisLogger.memory.info("Opened SQLite database at \(dbPath)")
                return
            }
        }

        // Fallback to in-memory SQLite if filesystem is unavailable
        if sqlite3_open(":memory:", &db) == SQLITE_OK {
            JarvisLogger.memory.warning("Using in-memory SQLite database fallback")
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
