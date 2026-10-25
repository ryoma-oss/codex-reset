import Foundation
import SQLite3
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
var history: OpaquePointer?, state: OpaquePointer?
precondition(sqlite3_open(dir.appendingPathComponent("thread_history_1.sqlite").path, &history) == SQLITE_OK)
precondition(sqlite3_open(dir.appendingPathComponent("state_5.sqlite").path, &state) == SQLITE_OK)
defer { sqlite3_close(history); sqlite3_close(state) }
func sql(_ db: OpaquePointer?, _ query: String) { precondition(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK) }
sql(history, "CREATE TABLE thread_turns(thread_id TEXT, turn_id TEXT, status TEXT, error_json TEXT, started_at INTEGER)")
sql(state, "CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, source TEXT, archived INTEGER, updated_at INTEGER, updated_at_ms INTEGER)")
let quota = #"{"codexErrorInfo":"usageLimitExceeded","message":"try again at 13:18"}"#
func turn(_ chat: String, _ turn: String, _ status: String, _ started: Int, _ error: String? = nil) {
    var stmt: OpaquePointer?
    precondition(sqlite3_prepare_v2(history, "INSERT INTO thread_turns VALUES(?, ?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, chat, -1, transient)
    sqlite3_bind_text(stmt, 2, turn, -1, transient)
    sqlite3_bind_text(stmt, 3, status, -1, transient)
    if let error { sqlite3_bind_text(stmt, 4, error, -1, transient) } else { sqlite3_bind_null(stmt, 4) }
    sqlite3_bind_int64(stmt, 5, Int64(started))
    precondition(sqlite3_step(stmt) == SQLITE_DONE)
}
for name in ["limited", "completed", "running", "interrupted", "other-error", "text-only", "malformed", "archived", "subagent", "fork-parent", "fork-child"] {
    let archived = name == "archived" ? 1 : 0
    let source = name == "subagent" ? #"{"subagent":{}}"# : "vscode"
    sql(state, "INSERT INTO threads VALUES('\(name)', '\(name)', '\(name)', '/fixture', '\(source)', \(archived), 0, 0)")
}
turn("limited", "z-old", "completed", 100)
turn("limited", "a-new", "failed", 1000, quota) // Timestamp outranks lexical turn ID.
for (name, status) in [("completed", "completed"), ("running", "inProgress"), ("interrupted", "interrupted"), ("other-error", "failed")] {
    turn(name, "a", "failed", 100, quota)
    turn(name, "b", status, 200, #"{"codexErrorInfo":"otherError"}"#)
}
turn("text-only", "a", "failed", 300, #"{"codexErrorInfo":"otherError","message":"mentions usageLimitExceeded"}"#)
turn("malformed", "a", "failed", 300, "not JSON usageLimitExceeded")
for name in ["archived", "subagent", "missing-state"] { turn(name, "a", "failed", 9000, quota) }
turn("fork-parent", "a", "failed", 100, quota)
turn("fork-parent", "b", "completed", 200)
turn("fork-child", "a", "failed", 2000, quota)
let reader = SQLiteReader(codexHome: dir.path)
let rows = reader.usageLimitedThreads()
precondition(rows.map(\.threadId) == ["fork-child", "limited"])
precondition(rows.last?.recoveryHint == "13:18")
precondition(reader.usageLimitedThreads(limit: 1).map(\.threadId) == ["fork-child"])
precondition(reader.usageLimitedThreads(limit: 0).isEmpty)
let all = Set(reader.allThreads().map(\.threadId))
precondition(rows.allSatisfy { all.contains($0.threadId) })
turn("limited", "b-new", "inProgress", 3000)
precondition(reader.usageLimitedThreads().map(\.threadId) == ["fork-child"])
print("PASS: latest quota failures only; resumed/completed/interrupted/other errors excluded; exact error code; visibility; fork isolation; ordering; post-filter limit; refresh")
