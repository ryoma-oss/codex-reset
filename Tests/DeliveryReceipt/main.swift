import Foundation
import SQLite3
let fm = FileManager.default
let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: dir) }
var db: OpaquePointer?
precondition(sqlite3_open(dir.appendingPathComponent("thread_history_1.sqlite").path, &db) == SQLITE_OK)
defer { sqlite3_close(db) }
precondition(sqlite3_exec(db, "CREATE TABLE thread_items (thread_id TEXT, item_type TEXT, rollout_ordinal INTEGER, item_json TEXT)", nil, nil, nil) == SQLITE_OK)
func add(_ thread: String, _ ordinal: Int, _ text: String, type: String = "userMessage") throws {
    let data = try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]]])
    var stmt: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, "INSERT INTO thread_items VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK)
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(stmt, 1, thread, -1, transient)
    sqlite3_bind_text(stmt, 2, type, -1, transient)
    sqlite3_bind_int64(stmt, 3, Int64(ordinal))
    sqlite3_bind_text(stmt, 4, String(data: data, encoding: .utf8), -1, transient)
    precondition(sqlite3_step(stmt) == SQLITE_DONE)
}
let receipt = DeliveryReceipt(codexHome: dir.path)
try add("target", 1, "Continue")
let baseline = try receipt.snapshot(threadId: "target")
precondition(baseline == 1)
var received = try receipt.received(threadId: "target", command: "Continue", after: baseline)
precondition(!received, "Old matching message must not count")
try add("other", 10, "Continue")
try add("target", 11, "Continue", type: "agentMessage")
try add("target", 12, "Continue later")
received = try receipt.received(threadId: "target", command: "Continue", after: baseline)
precondition(!received, "Other chat, assistant text, and substring must not count")
try add("target", 13, "Continue")
received = try receipt.received(threadId: "target", command: "Continue", after: baseline)
precondition(received)
let next = try receipt.snapshot(threadId: "target")
precondition(next == 13)
received = try receipt.received(threadId: "target", command: "Continue", after: next)
precondition(!received)
try add("target", 14, "Continue\n\n")
received = try receipt.received(threadId: "target", command: "Continue", after: next)
precondition(received, "Codex appends trailing newlines to user messages")
try add("target", 15, "Existing draftContinue\n")
received = try receipt.received(threadId: "target", command: "Continue", after: 14)
precondition(received, "User-requested append to an existing draft is valid delivery")
let missing = try receipt.snapshot(threadId: "'; DROP TABLE thread_items; --")
precondition(missing == -1)
do { _ = try DeliveryReceipt(codexHome: dir.appendingPathComponent("missing").path).snapshot(threadId: "target"); fatalError("Expected read error") }
catch { print("PASS: missing history reports error before sending") }
var cycle = RecoveryCycle()
cycle.confirm("target")
precondition(cycle.contains("target"))
cycle.begin()
precondition(!cycle.contains("target"), "Manual test must not poison next recovery")
cycle.confirm("target")
precondition(cycle.contains("target"), "Duplicate within same cycle must be skipped")
cycle.begin()
precondition(!cycle.contains("target"))
print("PASS: exact new message in target only, old/other/assistant/substring rejected, bound SQL, repeated recovery cycles")

// Real regression: user message is in the current rollout while history DB is stale.
var metadata: OpaquePointer?
precondition(sqlite3_open(dir.appendingPathComponent("state_5.sqlite").path, &metadata) == SQLITE_OK)
defer { sqlite3_close(metadata) }
let rollout = dir.appendingPathComponent("current-rollout.jsonl")
precondition(sqlite3_exec(metadata, "CREATE TABLE threads(id TEXT, rollout_path TEXT)", nil, nil, nil) == SQLITE_OK)
precondition(sqlite3_exec(metadata, "INSERT INTO threads VALUES ('target', '\(rollout.path)')", nil, nil, nil) == SQLITE_OK)
func message(_ text: String, role: String = "user", at: Date = Date()) throws -> Data {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var data = try JSONSerialization.data(withJSONObject: ["timestamp": formatter.string(from: at), "type": "response_item", "payload": ["type": "message", "role": role, "content": [["type": "input_text", "text": text]]]])
    data.append(0x0A); return data
}
try message("Continue", at: Date().addingTimeInterval(-120)).write(to: rollout)
let combined = try receipt.capture(threadId: "target")
precondition(combined.rollout != nil)
received = try receipt.received(threadId: "target", command: "Continue", after: combined)
precondition(!received)
let writer = try FileHandle(forWritingTo: rollout)
try writer.seekToEnd()
try writer.write(contentsOf: message("Continue", role: "assistant"))
try writer.write(contentsOf: message("Continue later"))
received = try receipt.received(threadId: "target", command: "Continue", after: combined)
precondition(!received)
try writer.write(contentsOf: message("Existing draftContinue\n"))
received = try receipt.received(threadId: "target", command: "Continue", after: combined)
precondition(received, "Rollout must confirm when SQLite history has no new item")
let nextRollout = try receipt.capture(threadId: "target")
try writer.write(contentsOf: message("Continue", at: Date().addingTimeInterval(-120)))
try writer.close()
received = try receipt.received(threadId: "target", command: "Continue", after: nextRollout)
precondition(!received, "Old delayed events must not confirm a new attempt")
try message("Continue").write(to: rollout, options: .atomic)
received = try receipt.received(threadId: "target", command: "Continue", after: nextRollout)
precondition(received, "Replacement rollout must be read using event time")
print("PASS: current rollout confirms with stale history; old/assistant/unrelated messages rejected; combined draft; replaced file")
