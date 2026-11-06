import Foundation
import AppKit
import ApplicationServices

/// GUI 自动化回退（Path B）：先用深链打开 Codex 对应对话，再粘贴「继续」并回车。
/// 依赖辅助功能权限（System Events）。
struct AppleScriptAutomation {
    static func activateApp() throws {
        try runAppleScript(#"tell application id "com.openai.codex" to activate"#)
    }

    /// 检测辅助功能权限
    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// 打开「系统设置 → 隐私与安全性 → 辅助功能」
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @discardableResult
    static func runAppleScript(_ script: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: data, encoding: .utf8) ?? "AppleScript 失败"
            throw JSONRPCError(code: -1, message: msg, data: nil)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// 自动继续引擎：
/// - Path A（首选）：连接桌面 app 的 app-server（remote_control），thread/resume + turn/start("继续")
/// - Path A 失效（无 socket / active writer / 未初始化）：回退 Path B（AppleScript GUI 自动化）
final class AutoContinueEngine {
    let codexHome: String
    /// 已处理过的线程，避免重复继续
    private var recoveryCycle = RecoveryCycle()

    var onLog: ((String, String) -> Void)?
    /// 需要重启 Codex 以启用 remote_control 时的回调（用于弹通知引导）
    var onNeedRestartCodex: (() -> Void)?
    /// 需要用户在系统设置授权辅助功能时的回调（不自动弹设置，由 UI 引导）
    var onNeedAccessibility: (() -> Void)?
    /// 最近一次继续失败的原因
    private(set) var lastFailureReason: String?
    private(set) var lastDesktopSummary: String?

    init(codexHome: String) {
        self.codexHome = codexHome
    }

    func alreadyHandled(_ threadId: String) -> Bool {
        recoveryCycle.contains(threadId)
    }

    func beginRecoveryCycle() { recoveryCycle.begin() }

    /// 继续指定线程。返回是否成功。
    /// - Parameters:
    ///   - client: 当前已连接的 app-server 客户端（可能是桌面 control 或独立实例）
    ///   - threadId: 目标线程
    ///   - command: 注入的指令（默认「继续」）
    ///   - fallbackToGUI: 是否允许回退 GUI 自动化
    func continueThread(client: AppServerClient?, threadId: String, command: String, fallbackToGUI: Bool, allowAppServer: Bool = true, resumeGoalBeforeSending: Bool = true) async -> Bool {
        var lastError = "无可用连接"
        lastFailureReason = nil
        lastDesktopSummary = nil

        // The menu-bar app must never acquire a thread writer through an app-server.
        // Its server connection is for quota reads only; continuation uses the desktop UI.
        if allowAppServer {
            // Path A1: 使用当前 app-server 客户端（优先桌面 control socket）
            if let client {
                if await tryContinueViaAppServer(client: client, threadId: threadId, command: command) {
                    recoveryCycle.confirm(threadId)
                    return true
                } else {
                    lastError = "app-server 通道失败"
                }
            }

            // Path A2: 尝试连接桌面 control socket（可能上次未连上）
            let manager = AppServerManager(codexHome: codexHome)
            if let desktopClient = try? manager.connectToDesktopControl() {
                do {
                    try await desktopClient.initialize()
                    if await tryContinueViaAppServer(client: desktopClient, threadId: threadId, command: command) {
                        recoveryCycle.confirm(threadId)
                        return true
                    }
                    lastError = "桌面 app-server 通道失败"
                } catch {
                    lastError = "桌面 app-server 初始化失败: \(error)"
                }
            }

        }

        // Path B: GUI 自动化回退
        if fallbackToGUI {
            if AppleScriptAutomation.hasAccessibilityPermission() {
                do {
                    let automation = await DesktopGoalAutomation(
                        codexHome: codexHome, threadId: threadId, resumeGoal: resumeGoalBeforeSending,
                        log: { [weak self] message in self?.onLog?(message, message) })
                    let receipt = DeliveryReceipt(codexHome: self.codexHome)
                    var baselines: [DeliveryReceipt.Baseline] = []
                    let result = try await ResumeAttempts.repeating(previouslyDelivered: {
                        for baseline in baselines {
                            do {
                                if try receipt.received(threadId: threadId, command: command, after: baseline) { return true }
                            } catch {
                                self.onLog?("到达确认读取失败：\(error.localizedDescription)", "Prior delivery check unavailable: \(error.localizedDescription)")
                            }
                        }
                        return false
                    }, log: { message in self.onLog?(message, message) }, attempt: { _ in
                        await ResumeAttempts.run(goal: {
                            self.onLog?("开始独立的 Goal 恢复操作", "Goal path starting: thread=\(threadId)")
                            return try await automation.resumeGoalIfNeeded()
                        }, message: {
                            self.onLog?("开始独立的 Continue 发送操作", "Continue path starting independently: thread=\(threadId)")
                            let before = try receipt.capture(threadId: threadId)
                            baselines.append(before)
                            self.onLog?("发送前聊天记录位置：\(before.ordinal ?? -1)", "GUI send baseline: thread=\(threadId), ordinal=\(before.ordinal.map(String.init) ?? "unavailable"), rollout=\(before.rollout != nil)")
                            try await automation.send(command: command)
                            for _ in 0..<30 {
                                if try receipt.received(threadId: threadId, command: command, after: before) {
                                    self.onLog?("已确认目标聊天收到消息：\(threadId)", "Delivery confirmed in target chat: thread=\(threadId)")
                                    return
                                }
                                try await Task.sleep(nanoseconds: 500_000_000)
                            }
                            throw desktopError("Message delivery unconfirmed after 15s.")
                        })
                    })
                    lastDesktopSummary = result.summary
                    onLog?(result.summary, result.summary)
                    if result.anySucceeded {
                        recoveryCycle.confirm(threadId)
                        return true
                    }
                    lastError = result.summary
                } catch {
                    lastError = "GUI 自动化失败: \(error)"
                }
            } else {
                lastError = "Accessibility permission is required for desktop continuation. Enable CodexReset in System Settings > Privacy & Security > Accessibility."
                onNeedAccessibility?()
            }
        }

        lastFailureReason = lastError
        if let err = lastAttemptError {
            lastFailureReason = "\(lastError)（\(err)）"
        }
        onLog?("继续失败：\(lastFailureReason ?? lastError)", "Continue failed: \(lastFailureReason ?? lastError)")
        return false
    }

    private func tryContinueViaAppServer(client: AppServerClient, threadId: String, command: String) async -> Bool {
        do {
            // 1) resume 加载线程
            _ = try await client.request("thread/resume", params: ["threadId": threadId])
            onLog?("已 resume 线程 \(threadId)", "Resumed thread \(threadId)")
            // 2) 开启新轮次
            let result = try await client.requestDecoded("turn/start", params: [
                "threadId": threadId,
                "input": [["type": "text", "text": command]]
            ], as: TurnStartResult.self)
            onLog?("turn/start 成功，turn 状态: \(result.turn.status)",
                   "turn/start succeeded, turn status: \(result.turn.status)")
            // 3) 后台监控 turn 完成，完成后释放线程写锁（否则 Codex 桌面 app 无法打开该对话）
            let turnId = result.turn.id
            Task {
                await Self.waitTurnCompletion(client: client, threadId: threadId, turnId: turnId)
                try? await client.request("thread/unsubscribe", params: ["threadId": threadId])
                onLog?("线程 \(threadId) 的 turn 已结束，已释放线程（Codex 可重新打开该对话）",
                       "Turn ended for thread \(threadId); thread released (Codex can reopen it)")
            }
            return true
        } catch {
            // 降噪：A 通道失败是预期（如 active writer），不输出「失败」日志，
            // 由 continueThread 记录 lastError；若 B 兜底成功则整体视为成功
            lastAttemptError = error
            // 失败时释放可能残留的 writer 锁
            try? await client.request("thread/unsubscribe", params: ["threadId": threadId])
            return false
        }
    }

    /// 最近一次 A 通道失败的具体原因（供排查；不直接打日志）
    private var lastAttemptError: Error?

    /// 轮询 turn 状态，直到非 inProgress/queued（completed/failed/interrupted）
    private static func waitTurnCompletion(client: AppServerClient, threadId: String, turnId: String) async {
        let deadline = Date().addingTimeInterval(6 * 3600) // 最多 6 小时
        while Date() < deadline {
            do {
                let dict = try await client.request("thread/turns/list", params: ["threadId": threadId])
                if let data = dict["data"] as? [[String: Any]],
                   let turn = data.first(where: { ($0["id"] as? String) == turnId }),
                   let status = turn["status"] as? String,
                   status != "inProgress", status != "queued", status != "pending" {
                    return
                }
            } catch {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 每 10 秒查一次
        }
    }
}
