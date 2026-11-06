import Foundation

struct RolloutTurnState {
    enum Status { case running, completed, interrupted, quotaFailure, otherFailure }
    let id: String
    let startedAt: TimeInterval
    var status: Status
    var errorMessage: String?
}

/// Read-only, incremental view of the current rollout when history DB indexing lags.
final class RolloutTurnStateReader {
    private struct Cache {
        let identity: String
        var modified: Date
        var offset: UInt64 = 0
        var partial = Data()
        var latest: RolloutTurnState?
    }
    private var cache: [String: Cache] = [:]

    func latest(path: String) -> RolloutTurnState? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let identity = "\(attributes[.systemNumber] ?? "")/\(attributes[.systemFileNumber] ?? "")"
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            var entry = cache[path] ?? Cache(identity: identity, modified: modified)
            if entry.identity != identity || size < entry.offset || (size == entry.offset && modified != entry.modified) {
                entry = Cache(identity: identity, modified: modified)
            }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seek(toOffset: entry.offset)
            while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                entry.partial.append(chunk)
                while let end = entry.partial.firstIndex(of: 0x0A) {
                    let line = Data(entry.partial[..<end])
                    entry.partial.removeSubrange(...end)
                    consume(line, latest: &entry.latest)
                }
            }
            entry.offset = try handle.offset()
            entry.modified = modified
            cache[path] = entry
            return entry.latest
        } catch { return nil }
    }

    private func consume(_ data: Data, latest: inout RolloutTurnState?) {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              row["type"] as? String == "event_msg",
              let payload = row["payload"] as? [String: Any], let type = payload["type"] as? String else { return }
        if type == "task_started" {
            guard let id = payload["turn_id"] as? String, let timestamp = row["timestamp"] as? String,
                  let date = Self.date(timestamp) else { return }
            if latest == nil || date.timeIntervalSince1970 >= latest!.startedAt {
                latest = RolloutTurnState(id: id, startedAt: date.timeIntervalSince1970, status: .running)
            }
            return
        }
        guard var state = latest else { return }
        if let id = payload["turn_id"] as? String, id != state.id { return }
        switch type {
        case "task_complete", "task_completed":
            if state.status == .running { state.status = .completed }
        case "task_aborted", "turn_aborted": state.status = .interrupted
        case "error":
            state.status = Self.isQuotaError(payload) ? .quotaFailure : .otherFailure
            state.errorMessage = payload["message"] as? String ?? (payload["error"] as? [String: Any])?["message"] as? String
        default: return
        }
        latest = state
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    private static func isQuotaError(_ value: Any) -> Bool {
        if let text = value as? String {
            return ["usageLimitExceeded", "usage_limit_exceeded"].contains(text) ||
                text.replacingOccurrences(of: "’", with: "'").hasPrefix("You've hit your usage limit.")
        }
        if let object = value as? [String: Any] { return object.values.contains(where: isQuotaError) }
        if let array = value as? [Any] { return array.contains(where: isQuotaError) }
        return false
    }
}
