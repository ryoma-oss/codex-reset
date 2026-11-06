import Foundation
import SQLite3

struct GoalState: Equatable {
    let id: String
    let status: String

    enum Action: Equatable { case resume, send, refuse }
    var action: Action {
        switch status {
        case "paused", "usage_limited": return .resume
        case "active": return .send
        default: return .refuse
        }
    }

    static func read(codexHome: String, threadId: String, onRetry: ((String) -> Void)? = nil) throws -> GoalState? {
        var initializeSidecars = false
        for attempt in 0..<4 {
            do { return try readOnce(codexHome: codexHome, threadId: threadId, initializeSidecars: initializeSidecars) }
            catch {
                let failure = error as NSError
                let transient = isRetryable(failure)
                guard transient, attempt < 3 else { throw error }
                if [Int(SQLITE_CANTOPEN), Int(SQLITE_READONLY)].contains(failure.code & 0xff) {
                    initializeSidecars = true
                }
                onRetry?("Goal DB read retry \(attempt + 1)/3, initializeSidecars=\(initializeSidecars), queryOnly=true: \(failure.localizedDescription)")
                Thread.sleep(forTimeInterval: [0.25, 0.5, 1.0][attempt])
            }
        }
        throw desktopError("Goal DB retries exhausted")
    }

    private static func readOnce(codexHome: String, threadId: String, initializeSidecars: Bool) throws -> GoalState? {
        let path = codexHome + "/goals_1.sqlite"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        // Never CREATE. The fallback permits SQLite's WAL/SHM housekeeping only;
        // query_only is enabled before executing the SELECT.
        let flags = initializeSidecars ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let error = databaseError(db, stage: "open", path: path)
            if let db { sqlite3_close(db) }
            throw error
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        guard sqlite3_exec(db, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(db, stage: "query_only", path: path)
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT goal_id, status FROM thread_goals WHERE thread_id = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw databaseError(db, stage: "prepare", path: path)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, threadId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW, let id = sqlite3_column_text(stmt, 0), let status = sqlite3_column_text(stmt, 1) else {
            throw databaseError(db, stage: "step", path: path)
        }
        return GoalState(id: String(cString: id), status: String(cString: status))
    }
    static func isRetryable(_ error: NSError) -> Bool {
        let baseCode = error.code & 0xff
        return error.domain == "CodexReset.GoalDatabase" &&
            [Int(SQLITE_BUSY), Int(SQLITE_LOCKED), Int(SQLITE_SCHEMA), Int(SQLITE_PROTOCOL),
             Int(SQLITE_READONLY), Int(SQLITE_CANTOPEN)].contains(baseCode)
    }

    private static func databaseError(_ db: OpaquePointer?, stage: String, path: String) -> NSError {
        let code = sqlite3_extended_errcode(db)
        let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
        let systemError = sqlite3_system_errno(db)
        let fm = FileManager.default
        let files = [path, path + "-wal", path + "-shm"].map { file in
            "\(URL(fileURLWithPath: file).lastPathComponent){exists=\(fm.fileExists(atPath: file)),readable=\(fm.isReadableFile(atPath: file)),writable=\(fm.isWritableFile(atPath: file))}"
        }.joined(separator: ",")
        let parentWritable = fm.isWritableFile(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
        return NSError(domain: "CodexReset.GoalDatabase", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Goal database \(stage) failed (SQLite \(code), system errno \(systemError)): \(message); parentWritable=\(parentWritable); \(files)"])
    }

}

func desktopError(_ text: String) -> NSError {
    NSError(domain: "CodexReset.Desktop", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
}
