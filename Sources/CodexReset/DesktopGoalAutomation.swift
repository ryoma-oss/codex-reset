import Foundation
import AppKit
import ApplicationServices

/// Called by the installed app, not by the development test runner.
/// Goal state and target history are read-only; all changes use the desktop UI.
@MainActor
struct DesktopGoalAutomation {
    let codexHome: String
    let threadId: String
    let resumeGoal: Bool
    let log: (String) -> Void

    static let resumeLabels: Set<String> = ["目標を再開", "Resume goal", "Resume Goal", "恢复目标", "继续目标"]

    static func normalized(_ text: String) -> String {
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}\u{2060}"))
        return text.trimmingCharacters(in: padding)
    }

    func resumeGoalIfNeeded() async throws -> ResumeStep {
        guard resumeGoal else { return .skipped("disabled") }
        guard let original = try GoalState.read(codexHome: codexHome, threadId: threadId, onRetry: log) else {
            return .skipped("no Goal")
        }
        if original.status == "active" { return .skipped("already active") }
        guard original.action == .resume else { return .skipped("status=\(original.status)") }
        let (app, root, window, title) = try await openVerifiedTarget()
        guard try GoalState.read(codexHome: codexHome, threadId: threadId, onRetry: log) == original else {
            throw desktopError("Goal changed before click; stopped")
        }
        var candidates: [AXUIElement] = []
        let buttonDeadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            try verifyFront(app, root: root, window: window, title: title)
            candidates = controlElements(window, stage: "goal").filter { element in
                string(element, kAXRoleAttribute) == kAXButtonRole && enabled(element) &&
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].contains {
                    Self.resumeLabels.contains(Self.normalized(string(element, $0)))
                }
            }
            if candidates.count == 1 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while ProcessInfo.processInfo.systemUptime < buttonDeadline
        if candidates.count != 1 {
            let related = elements(window).filter { string($0, kAXRoleAttribute) == kAXButtonRole }.compactMap { item -> String? in
                let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { string(item, $0) }.joined(separator: " / ")
                guard ["resume", "再開", "恢复", "继续"].contains(where: { label.lowercased().contains($0) }) else { return nil }
                return "\(label.prefix(160)) [enabled=\(enabled(item))]"
            }
            log("Goal resume related controls: \(related.prefix(12).joined(separator: "; "))")
        }
        log("Goal resume preflight: thread=\(threadId), goal=\(original.id), status=\(original.status), matchingButtons=\(candidates.count)")
        guard candidates.count == 1, let button = candidates.first else {
            throw desktopError("Expected one enabled Goal resume button; found \(candidates.count). Nothing clicked or typed.")
        }
        try verifyFront(app, root: root, window: window, title: title)
        try click(button, within: window, maxDimension: 200)
        log("Goal resume button clicked once: thread=\(threadId), goal=\(original.id)")
        var active = false
        for _ in 0..<30 {
            let current = try GoalState.read(codexHome: codexHome, threadId: threadId, onRetry: log)
            guard current?.id == original.id else { throw desktopError("Goal was replaced or removed after click; Goal confirmation stopped") }
            if current?.status == "active" { active = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard active else { throw desktopError("Goal activation unconfirmed after 15s; Goal confirmation stopped. No automatic retry.") }
        log("Goal active confirmed: thread=\(threadId), goal=\(original.id)")
        return .succeeded
    }

    func send(command: String) async throws {
        guard !Self.normalized(command).isEmpty else { throw desktopError("Command is empty") }
        let (app, root, window, title) = try await openVerifiedTarget()
        // Only one visible multiline editor is accepted; never guess composer coordinates.
        var editors: [AXUIElement] = []
        let editorDeadline = ProcessInfo.processInfo.systemUptime + 10
        repeat {
            try verifyFront(app, root: root, window: window, title: title)
            let nodes = controlElements(window, stage: "composer")
            let textAreas = nodes.filter { string($0, kAXRoleAttribute) == kAXTextAreaRole }
            editors = textAreas.filter { enabled($0) && rect($0) != nil }
            log("Composer preflight: thread=\(threadId), rawTextAreas=\(textAreas.count), textAreas=\(editors.count), disabled=\(textAreas.filter { !enabled($0) }.count), missingBounds=\(textAreas.filter { rect($0) == nil }.count)")
            if editors.count == 1 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        } while ProcessInfo.processInfo.systemUptime < editorDeadline
        guard editors.count == 1, let editor = editors.first else {
            throw desktopError("Cannot identify one composer after waiting for UI readiness; nothing typed or sent")
        }
        try click(editor, within: window, maxDimension: 10000)
        try await Task.sleep(nanoseconds: 300_000_000)
        try verifyEditor(root, editor: editor)
        // Explicit user preference: keep existing text and append the command without an emptiness check.
        do {
            let clipboard = NSPasteboard.general
            let saved = clipboard.pasteboardItems?.map { item in
                item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                    item.data(forType: type).map { (type, $0) }
                }
            } ?? []
            defer {
                clipboard.clearContents()
                let items = saved.map { contents -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in contents { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { clipboard.writeObjects(items) }
            }
            clipboard.clearContents()
            clipboard.setString(command, forType: .string)
            try verifyFront(app, root: root, window: window, title: title)
            try verifyEditor(root, editor: editor)
            try key(124, flags: .maskCommand) // Move to end of line.
            try key(125, flags: .maskCommand) // Move to end of the composer without selecting.
            try await Task.sleep(nanoseconds: 100_000_000)
            try verifyEditor(root, editor: editor)
            try key(9, flags: .maskCommand)
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        try verifyFront(app, root: root, window: window, title: title)
        try verifyEditor(root, editor: editor)
        try key(36, flags: [])
        log("Enter sent once after appending command: thread=\(threadId)")
    }

    private func openVerifiedTarget() async throws -> (NSRunningApplication, AXUIElement, AXUIElement, String) {
        let chats = SQLiteReader(codexHome: codexHome).allThreads()
        guard let title = chats.first(where: { $0.threadId == threadId })?.title,
              chats.filter({ $0.title == title }).count == 1 else {
            throw desktopError("Target chat title is missing or ambiguous. Nothing clicked or typed.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first,
              let url = URL(string: "codex://threads/\(threadId)") else { throw desktopError("Codex is not running") }
        guard NSWorkspace.shared.open(url) else { throw desktopError("Cannot open target chat") }
        app.activate(options: [.activateIgnoringOtherApps])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var target: AXUIElement?
        for _ in 0..<20 {
            if let window = focusedWindow(root), identifies(window, title: title) { target = window; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let window = target else {
            let title = focusedWindow(root).map { string($0, kAXTitleAttribute) } ?? "<none>"
            log("Target verification failed: focusedWindow=\(title). Nothing clicked or typed.")
            throw desktopError("Cannot verify target chat by window title or selected sidebar item")
        }
        try verifyFront(app, root: root, window: window, title: title)
        return (app, root, window, title)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    private func enabled(_ element: AXUIElement) -> Bool { (attribute(element, kAXEnabledAttribute) as? Bool) == true }
    private func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
        guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private struct Node: Hashable {
        let element: AXUIElement
        static func == (lhs: Node, rhs: Node) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    private func scan(_ root: AXUIElement, limit: Int, seconds: TimeInterval) -> (BoundedTreeScan<Node>, [Int: Int]) {
        var errors: [Int: Int] = [:]
        let tree = scanTree(root: Node(element: root), maxNodes: limit, maxSeconds: seconds) { node in
            var value: CFTypeRef?
            let rc = AXUIElementCopyAttributeValue(node.element, kAXChildrenAttribute as CFString, &value)
            if rc != .success && rc != .attributeUnsupported && rc != .noValue {
                errors[Int(rc.rawValue), default: 0] += 1
            }
            return (value as? [AXUIElement] ?? []).map { Node(element: $0) }
        }
        return (tree, errors)
    }
    private func elements(_ root: AXUIElement) -> [AXUIElement] {
        scan(root, limit: 6000, seconds: 2).0.nodes.map(\.element)
    }
    private func controlElements(_ window: AXUIElement, stage: String) -> [AXUIElement] {
        var (tree, errors) = scan(window, limit: 6000, seconds: 2)
        var limit = 6000
        if tree.limitHit {
            log("AX scan expanding: thread=\(threadId), stage=\(stage), visited=\(tree.nodes.count), pending=\(tree.pendingCount), limitHit=true")
            (tree, errors) = scan(window, limit: 20000, seconds: 4)
            limit = 20000
        }
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<none>"
        let errorText = errors.keys.sorted().map { "\($0):\(errors[$0]!)" }.joined(separator: ",")
        log("AX scan: thread=\(threadId), stage=\(stage), visited=\(tree.nodes.count), admitted=\(tree.admittedCount), pending=\(tree.pendingCount), limit=\(limit), limitHit=\(tree.limitHit), timedOut=\(tree.timedOut), childErrors=[\(errorText)], front=\(front), active=\(app?.isActive ?? false), hidden=\(app?.isHidden ?? false), axTrusted=\(AXIsProcessTrusted()), windowTitle=\(string(window, kAXTitleAttribute))")
        return tree.nodes.map(\.element)
    }
    private func identifies(_ window: AXUIElement, title: String) -> Bool {
        if Self.normalized(string(window, kAXTitleAttribute)) == title { return true }
        return elements(window).contains { item in
            guard (attribute(item, kAXSelectedAttribute) as? Bool) == true else { return false }
            return elements(item).contains { child in
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains {
                    Self.normalized(string(child, $0)) == title
                }
            }
        }
    }
    private func verifyFront(_ app: NSRunningApplication, root: AXUIElement, window: AXUIElement, title: String) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current = focusedWindow(root), CFEqual(current, window), identifies(current, title: title) else {
            throw desktopError("Target chat or focus changed; stopped")
        }
    }
    private func verifyEditor(_ root: AXUIElement, editor: AXUIElement) throws {
        guard let focused = attribute(root, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            throw desktopError("Composer focus cannot be verified")
        }
        var node = unsafeBitCast(focused, to: AXUIElement.self)
        for _ in 0..<6 {
            if CFEqual(node, editor) { return }
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
        }
        throw desktopError("Composer is not focused; nothing sent")
    }
    private func rect(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    private func click(_ element: AXUIElement, within window: AXUIElement, maxDimension: CGFloat) throws {
        guard let r = rect(element), let w = rect(window),
              r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
              r.width >= 4, r.height >= 4, r.width <= maxDimension, r.height <= maxDimension,
              w.contains(r) else { throw desktopError("UI element bounds unavailable or unsafe; nothing clicked") }
        let point = CGPoint(x: r.midX, y: r.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw desktopError("Cannot create mouse input")
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    private func key(_ code: CGKeyCode, flags: CGEventFlags) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw desktopError("Cannot create keyboard input") }
        down.flags = flags; up.flags = flags
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
}
