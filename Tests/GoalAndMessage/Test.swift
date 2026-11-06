import Foundation
import SQLite3

@main struct Tests {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        var db: OpaquePointer?
        precondition(sqlite3_open(dir.appendingPathComponent("goals_1.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        func sql(_ text: String) { precondition(sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK) }
        sql("CREATE TABLE thread_goals (thread_id TEXT PRIMARY KEY, goal_id TEXT, status TEXT)")
        sql("INSERT INTO thread_goals VALUES ('target', 'same-goal', 'paused')")
        var state = try GoalState.read(codexHome: dir.path, threadId: "target")
        precondition(state?.action == .resume)
        sql("UPDATE thread_goals SET status='usage_limited'")
        state = try GoalState.read(codexHome: dir.path, threadId: "target")
        precondition(state?.action == .resume)
        sql("UPDATE thread_goals SET status='active'")
        state = try GoalState.read(codexHome: dir.path, threadId: "target")
        precondition(state?.action == .send && state?.id == "same-goal")
        for status in ["complete", "blocked", "budget_limited", "unknown"] {
            sql("UPDATE thread_goals SET status='\(status)'")
            state = try GoalState.read(codexHome: dir.path, threadId: "target")
            precondition(state?.action == .refuse)
        }
        let absent = try GoalState.read(codexHome: dir.path, threadId: "' OR 1=1 --")
        precondition(absent == nil)
        // Exercise a real prepare-time lock using a separate connection on a worker.
        let ready = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let databasePath = dir.appendingPathComponent("goals_1.sqlite").path
        DispatchQueue.global().async {
            var lockDB: OpaquePointer?
            precondition(sqlite3_open(databasePath, &lockDB) == SQLITE_OK)
            precondition(sqlite3_exec(lockDB, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
            ready.signal()
            Thread.sleep(forTimeInterval: 0.85)
            precondition(sqlite3_exec(lockDB, "COMMIT", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(lockDB)
            released.signal()
        }
        ready.wait()
        var retryCount = 0
        let recovered = try GoalState.read(codexHome: dir.path, threadId: "target", onRetry: { _ in retryCount += 1 })
        released.wait()
        precondition(recovered?.id == "same-goal" && retryCount > 0)
        // A real missing table must retain its SQLite reason, not a generic schema label.
        sql("ALTER TABLE thread_goals RENAME TO missing_goal_table")
        do { _ = try GoalState.read(codexHome: dir.path, threadId: "target"); fatalError("Expected schema error") }
        catch { precondition(error.localizedDescription.contains("no such table")) }
        precondition(DesktopGoalAutomation.resumeLabels.contains("目標を再開"))
        precondition(!DesktopGoalAutomation.resumeLabels.contains("Resume"), "Generic buttons must not match")
        // Actual incident: only the leading Markdown heading differs.
        let savedTitle = "# 東京発スキーツアー全件調査（2026年11月・12月）## 目的…"
        let shownTitle = "東京発スキーツアー全件調査（2026年11月・12月）## 目的…"
        precondition(ChatTitleIdentity.matches(shownTitle, savedTitle))
        precondition(ChatTitleIdentity.matches("東京発", "\\# 東京発"))
        precondition(!ChatTitleIdentity.matches("東京発 (2)", savedTitle))
        precondition(!ChatTitleIdentity.matches("sale", "#sale"))
        precondition(ChatTitleIdentity.key("\\#sale") == "\\#sale")
        precondition(!ChatTitleIdentity.isUnique(savedTitle, among: [savedTitle, shownTitle]))
        precondition(ChatTitleIdentity.isUnique(savedTitle, among: [savedTitle, "Other chat"]))
        precondition(GoalState.isRetryable(NSError(domain: "CodexReset.GoalDatabase", code: Int(SQLITE_CANTOPEN))))
        precondition(!GoalState.isRetryable(NSError(domain: "CodexReset.GoalDatabase", code: Int(SQLITE_CORRUPT))))
        // Reproduce prepare-time CANTOPEN with an inaccessible WAL path, then repair the fixture.
        let walDir = dir.appendingPathComponent("wal-fixture")
        try fm.createDirectory(at: walDir, withIntermediateDirectories: true)
        let walPath = walDir.appendingPathComponent("goals_1.sqlite").path
        var walWriter: OpaquePointer?
        precondition(sqlite3_open(walPath, &walWriter) == SQLITE_OK)
        precondition(sqlite3_exec(walWriter, "PRAGMA journal_mode=WAL; CREATE TABLE thread_goals(thread_id TEXT, goal_id TEXT, status TEXT); INSERT INTO thread_goals VALUES ('target', 'wal-goal', 'paused');", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_exec(walWriter, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_close(walWriter) == SQLITE_OK)
        let inaccessibleWAL = walPath + "-wal"
        // Fixture only: all writes are checkpointed and the writer is closed.
        for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: walPath + suffix) {
            try fm.removeItem(atPath: walPath + suffix)
        }
        try fm.createDirectory(atPath: inaccessibleWAL, withIntermediateDirectories: false)
        var walRetries: [String] = []
        let walGoal = try GoalState.read(codexHome: walDir.path, threadId: "target", onRetry: { message in
            walRetries.append(message)
            if fm.fileExists(atPath: inaccessibleWAL) { try! fm.removeItem(atPath: inaccessibleWAL) }
        })
        precondition(walGoal?.id == "wal-goal" && !walRetries.isEmpty)
        print("PASS: WAL sidecar access failure recovered after reopening: \(walRetries.first!)")
        print("PASS: incident title match, legitimate hash preserved, title collisions refused, SQLite CANTOPEN retried")
        let capped = scanTree(root: 0, maxNodes: 4, maxSeconds: 10) { node in node == 0 ? [1, 2, 3, 4] : [] }
        precondition(capped.nodes == [0, 1, 2, 3] && capped.pendingCount == 0 && capped.limitHit)
        let cyclic = scanTree(root: 0, maxNodes: 10, maxSeconds: 10) { node in node == 0 ? [1, 1] : [0] }
        precondition(cyclic.nodes == [0, 1] && !cyclic.limitHit)
        var clock: TimeInterval = 0
        let timeout = scanTree(root: 0, maxNodes: 10, maxSeconds: 2, now: { clock += 1; return clock }) { _ in [1, 2] }
        precondition(timeout.timedOut && timeout.pendingCount > 0)
        let expanded = scanTree(root: 0, maxNodes: 8, maxSeconds: 10) { node in node == 0 ? Array(1...6) : [] }
        precondition(expanded.nodes.contains(6) && !expanded.limitHit)
        print("PASS: queued nodes processed at limit, cycles deduplicated, timeout reported, larger scan reaches later controls")
        // Failure in either path must not gate the other path.
        let failure = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "injected failure"])
        for goalFails in [false, true] {
            for messageFails in [false, true] {
                var calls: [String] = []
                let result = await ResumeAttempts.run(goal: {
                    calls.append("goal")
                    if goalFails { throw failure }
                    return .succeeded
                }, message: {
                    calls.append("message")
                    if messageFails { throw failure }
                })
                precondition(calls == ["goal", "message"])
                precondition(result.goal.succeeded == !goalFails)
                precondition(result.message.succeeded == !messageFails)
                precondition(result.anySucceeded == (!goalFails || !messageFails))
            }
        }
        var sentWithoutGoal = false
        let skipped = await ResumeAttempts.run(goal: { .skipped("no Goal") }, message: { sentWithoutGoal = true })
        precondition(sentWithoutGoal && skipped.message.succeeded)
        print("PASS: independent paths: Goal read/button failures cannot block message; message failure preserves Goal success; both failures recorded; no-Goal still sends")
        print("PASS: paused/usage_limited resume, active sends, other states refuse; bound SQL. No live UI events executed.")
    }
}
