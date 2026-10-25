import Foundation
import SQLite3

/// SQLite 的 SQLITE_TRANSIENT 是 C 宏，Swift 里需手动定义
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 从本地 sqlite 定位「因用量用光而暂停」的对话
struct PausedThread {
    let threadId: String
    let title: String
    let cwd: String
    /// 错误消息里的恢复提示原文，如 "try again at 1:17 PM"
    let recoveryHint: String?
    /// 该失败轮次时间（Unix 秒）
    let failedAt: Int
}

final class SQLiteReader {
    let codexHome: String

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    private var threadHistoryPath: String { codexHome + "/thread_history_1.sqlite" }
    private var stateDbPath: String { codexHome + "/state_5.sqlite" }

    /// Show only chats whose latest turn is a quota-limit failure.
    /// A subsequent completed/running/interrupted/other-failure turn removes the chat.
    func usageLimitedThreads(limit: Int = 20) -> [PausedThread] {
        guard limit > 0 else { return [] }
        guard let rows = queryRows(
            path: threadHistoryPath,
            sql: """
            WITH latest AS (
                SELECT thread_id, error_json, started_at, turn_id, status,
                       ROW_NUMBER() OVER (
                           PARTITION BY thread_id ORDER BY started_at DESC, turn_id DESC
                       ) AS position
                FROM thread_turns
            )
            SELECT thread_id, error_json, started_at FROM latest
            WHERE position = 1 AND status = 'failed'
              AND error_json LIKE '%usageLimitExceeded%'
            ORDER BY started_at DESC, turn_id DESC
            """
        ) else { return [] }

        var result: [PausedThread] = []
        for row in rows {
            let threadId = row[0] as? String ?? ""
            let errorJson = row[1] as? String ?? ""
            let failedAt = row[2] as? Int ?? 0
            guard !threadId.isEmpty else { continue }
            // Match All chats visibility, and verify the actual error code rather than message text.
            guard let state = queryRow(path: stateDbPath,
                                       sql: "SELECT source, archived FROM threads WHERE id = ?", args: [threadId]),
                  let source = state[0] as? String, let archived = state[1] as? Int,
                  archived == 0, !source.trimmingCharacters(in: .whitespaces).hasPrefix(#"{"subagent""#),
                  let data = errorJson.data(using: .utf8),
                  let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  error["codexErrorInfo"] as? String == "usageLimitExceeded" else { continue }
            let title = displayTitle(threadId: threadId, stateTitle: threadTitle(threadId: threadId))
            let cwd = threadCwd(threadId: threadId) ?? ""
            let hint = Self.extractRecoveryHint(from: errorJson)
            result.append(PausedThread(threadId: threadId, title: title, cwd: cwd,
                                       recoveryHint: hint, failedAt: failedAt))
            if result.count >= limit { break }
        }
        return result
    }

    /// 列出所有对话（含未暂停的），按项目分组用；过滤归档与子代理线程，最新在前
    func allThreads(limit: Int = 1000) -> [PausedThread] {
        guard let rows = queryRows(path: stateDbPath, sql: """
            SELECT id, COALESCE(NULLIF(TRIM(name), ''), title), cwd, updated_at
            FROM threads
            WHERE archived = 0 AND source NOT LIKE '{"subagent"%'
            ORDER BY updated_at_ms DESC
            LIMIT ?
        """, args: [limit]) else { return [] }

        var result: [PausedThread] = []
        for row in rows {
            let threadId = row[0] as? String ?? ""
            let rawTitle = row[1] as? String
            let cwd = row[2] as? String ?? ""
            let updatedAt = row[3] as? Int ?? 0
            guard !threadId.isEmpty else { continue }
            let title = displayTitle(threadId: threadId, stateTitle: rawTitle)
            result.append(PausedThread(threadId: threadId, title: title, cwd: cwd,
                                       recoveryHint: nil, failedAt: updatedAt))
        }
        return result
    }

    /// 判断是否为子代理线程（state 库 source 以 {"subagent" 开头）
    private func isSubagentThread(threadId: String) -> Bool {
        guard let source = threadSource(threadId: threadId) else { return false }
        return source.trimmingCharacters(in: .whitespaces).hasPrefix(#"{"subagent""#)
    }

    private func threadSource(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT source FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    /// Prefer the visible Codex chat name. The legacy title often contains the
    /// entire initial prompt, so unnamed chats use the newest meaningful user text.
    private func fallbackTitle(threadId: String) -> String? {
        guard let rows = queryRows(path: threadHistoryPath, sql: """
            SELECT item_json FROM thread_items
            WHERE thread_id = ? AND item_type = 'userMessage'
            ORDER BY rollout_ordinal DESC LIMIT 30
        """, args: [threadId]) else { return nil }
        for row in rows {
            guard let json = row[0] as? String,
                  let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = obj["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
            let cleaned = compactTitle(text)
            if !cleaned.isEmpty && !isContinuation(cleaned) && !cleaned.hasPrefix("<environment_context>") {
                return cleaned
            }
        }
        return nil
    }

    private func compactTitle(_ text: String) -> String {
        let cleaned = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return cleaned.count > 80 ? String(cleaned.prefix(80)) + "…" : cleaned
    }

    private func isContinuation(_ text: String) -> Bool {
        ["continue", "继续", "続けて", "/goal resume"].contains(text.lowercased())
    }

    private func displayTitle(threadId: String, stateTitle: String?) -> String {
        if let name = queryRow(path: stateDbPath,
                               sql: "SELECT name FROM threads WHERE id = ?",
                               args: [threadId])?[0] as? String {
            let cleaned = compactTitle(name)
            if !cleaned.isEmpty { return cleaned }
        }
        if let latest = fallbackTitle(threadId: threadId) { return latest }
        if let stateTitle {
            let cleaned = compactTitle(stateTitle)
            if !cleaned.isEmpty && !isContinuation(cleaned) { return cleaned }
        }
        return "Untitled chat (" + String(threadId.prefix(8)) + ")"
    }

    private func threadTitle(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT COALESCE(NULLIF(TRIM(name), ''), title) FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    private func threadCwd(threadId: String) -> String? {
        queryRow(path: stateDbPath,
                 sql: "SELECT cwd FROM threads WHERE id = ?",
                 args: [threadId])?[0] as? String
    }

    /// 从错误 JSON 中提取 "try again at ..." 恢复提示
    static func extractRecoveryHint(from errorJson: String) -> String? {
        guard let data = errorJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String else {
            return nil
        }
        if let range = message.range(of: "try again at ") {
            return String(message[range.upperBound...])
        }
        return nil
    }

    // MARK: - 通用查询

    private func queryRow(path: String, sql: String, args: [Any] = []) -> [Any?]? {
        queryRows(path: path, sql: sql, args: args)?.first
    }

    /// 多行查询
    private func queryRows(path: String, sql: String, args: [Any] = []) -> [[Any?]]? {
        guard let db = open(path) else {
            #if DEBUG
            FileHandle.standardError.write("[SQLITE-OPEN-FAIL] \(path)\n".data(using: .utf8)!)
            #endif
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            #if DEBUG
            let err = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "?"
            FileHandle.standardError.write("[SQLITE-PREPARE-FAIL] \(err)\n".data(using: .utf8)!)
            #endif
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            if let s = arg as? String {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            } else if let n = arg as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }

        let count = sqlite3_column_count(stmt)
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                var row: [Any?] = []
                for i in 0..<count {
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row.append(Int(sqlite3_column_int64(stmt, i)))
                    case SQLITE_TEXT:
                        if let c = sqlite3_column_text(stmt, i) {
                            row.append(String(cString: c))
                        } else {
                            row.append(nil)
                        }
                    case SQLITE_NULL:
                        row.append(nil)
                    case SQLITE_FLOAT:
                        row.append(sqlite3_column_double(stmt, i))
                    default:
                        if let c = sqlite3_column_text(stmt, i) {
                            row.append(String(cString: c))
                        } else {
                            row.append(nil)
                        }
                    }
                }
                rows.append(row)
            } else if rc == SQLITE_DONE {
                break
            } else {
                #if DEBUG
                let err = sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "rc=\(rc)"
                FileHandle.standardError.write("[SQLITE-STEP-FAIL] \(err)\n".data(using: .utf8)!)
                #endif
                return nil
            }
        }
        return rows
    }

    private func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        // 用 READWRITE 而非 READONLY：WAL 模式数据库在并发写时 readonly 打开可能失败
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        guard rc == SQLITE_OK else {
            let msg = (db.flatMap { sqlite3_errmsg($0) }).flatMap { String(cString: $0) } ?? "rc=\(rc)"
            #if DEBUG
            FileHandle.standardError.write("[SQLITE-OPEN-ERR] \(path): \(msg)\n".data(using: .utf8)!)
            #endif
            if let db { sqlite3_close(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 5000)
        return db
    }
}

// MARK: - config.toml 读取

/// 读取 ~/.codex/config.toml 中的相关配置
struct CodexConfig {
    let remoteControlEnabled: Bool

    static func load(codexHome: String) -> CodexConfig {
        let path = codexHome + "/config.toml"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return CodexConfig(remoteControlEnabled: false)
        }
        var remoteControl = false
        var inFeatures = false
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inFeatures = (line == "[features]")
                continue
            }
            if inFeatures && line.hasPrefix("remote_control") {
                remoteControl = line.lowercased().contains("true")
            }
        }
        return CodexConfig(remoteControlEnabled: remoteControl)
    }

    /// 写入 [features] remote_control = true/false（保留原有内容；需重启 Codex 桌面 app 生效）
    /// 注意：必须复用已有的 [features] 段，不能重复定义，否则 TOML 报 duplicate key
    @discardableResult
    static func setRemoteControl(codexHome: String, enabled: Bool) -> Bool {
        let path = codexHome + "/config.toml"
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = content.components(separatedBy: "\n")
        let value = enabled ? "true" : "false"

        // 找到所有段标题行（以 [ 开头 ] 结尾）
        let sectionIndices = lines.indices.filter {
            let t = lines[$0].trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.hasSuffix("]")
        }
        // 定位 [features] 段
        var featuresStart: Int?
        for idx in sectionIndices where lines[idx].trimmingCharacters(in: .whitespaces) == "[features]" {
            featuresStart = idx
            break
        }

        var modified = false
        if let start = featuresStart {
            // 段范围：start ..< 下一个段标题（或文件末尾）
            let end = sectionIndices.first(where: { $0 > start }) ?? lines.count
            var inserted = false
            for i in start..<end {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("remote_control") {
                    lines[i] = "remote_control = \(value)"
                    inserted = true
                    modified = true
                    break
                }
            }
            if !inserted {
                // 在段内末尾插入
                lines.insert("remote_control = \(value)", at: end)
                modified = true
            }
        } else {
            // 完全没有 [features] 段才追加新段
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            lines.append("")
            lines.append("[features]")
            lines.append("remote_control = \(value)")
            modified = true
        }

        guard modified else { return true }
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
