import Foundation
import SQLite3

struct RolloutMessageCursor {
    let path: String
    let identity: String
    let offset: UInt64
    let capturedAt: Date
}

/// Delivery evidence from the current rollout, including restored chats not yet indexed in history.
enum RolloutMessageReceipt {
    static func capture(codexHome: String, threadId: String, at: Date) -> RolloutMessageCursor? {
        guard let path = currentPath(codexHome: codexHome, threadId: threadId),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return RolloutMessageCursor(path: path, identity: identity(attributes),
                                    offset: (attributes[.size] as? NSNumber)?.uint64Value ?? 0, capturedAt: at)
    }

    static func received(codexHome: String, threadId: String, command: String, after cursor: RolloutMessageCursor) throws -> Bool {
        let path = currentPath(codexHome: codexHome, threadId: threadId) ?? cursor.path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let sameFile = path == cursor.path && identity(attributes) == cursor.identity && size >= cursor.offset
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seek(toOffset: sameFile ? cursor.offset : 0)
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[..<end]); pending.removeSubrange(...end)
                if matches(line, command: command, since: cursor.capturedAt.addingTimeInterval(-1)) { return true }
            }
        }
        return false
    }

    private static func matches(_ data: Data, command: String, since: Date) -> Bool {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = row["timestamp"] as? String, let time = date(timestamp), time >= since,
              let payload = row["payload"] as? [String: Any] else { return false }
        let text: String
        if row["type"] as? String == "response_item", payload["type"] as? String == "message",
           payload["role"] as? String == "user", let parts = payload["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else if row["type"] as? String == "event_msg", payload["type"] as? String == "user_message",
                  let message = payload["message"] as? String {
            text = message
        } else { return false }
        let expected = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return !expected.isEmpty && text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(expected)
    }

    private static func currentPath(codexHome: String, threadId: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(codexHome + "/state_5.sqlite", &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let path = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: path)
    }
    private static func identity(_ attributes: [FileAttributeKey: Any]) -> String {
        "\(attributes[.systemNumber] ?? "")/\(attributes[.systemFileNumber] ?? "")"
    }
    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
