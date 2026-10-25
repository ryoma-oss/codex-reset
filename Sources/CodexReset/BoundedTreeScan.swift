import Foundation

struct BoundedTreeScan<Node> {
    let nodes: [Node]
    let admittedCount: Int
    let limitHit: Bool
    let timedOut: Bool
    var pendingCount: Int { admittedCount - nodes.count }
}

func scanTree<Node: Hashable>(root: Node, maxNodes: Int,
                             maxSeconds: TimeInterval,
                             now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                             children: (Node) -> [Node]) -> BoundedTreeScan<Node> {
    precondition(maxNodes > 0)
    var queue = [root], visited: Set<Node> = [root], offset = 0
    var limited = false, timedOut = false
    let deadline = now() + maxSeconds
    // Reaching the admission limit must not discard already queued nodes.
    while offset < queue.count {
        if now() >= deadline { timedOut = true; break }
        let node = queue[offset]
        offset += 1
        for child in children(node) where !visited.contains(child) {
            guard queue.count < maxNodes else { limited = true; continue }
            visited.insert(child)
            queue.append(child)
        }
    }
    return BoundedTreeScan(nodes: Array(queue.prefix(offset)), admittedCount: queue.count,
                           limitHit: limited, timedOut: timedOut)
}
