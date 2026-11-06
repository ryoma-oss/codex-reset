import Foundation

enum ResumeStep: Equatable {
    case succeeded
    case skipped(String)
    case failed(String)

    var succeeded: Bool { if case .succeeded = self { return true }; return false }
    var description: String {
        switch self {
        case .succeeded: return "confirmed"
        case .skipped(let reason): return "skipped (\(reason))"
        case .failed(let reason): return "failed (\(reason))"
        }
    }
}

struct ResumeAttempts {
    let goal: ResumeStep
    let message: ResumeStep
    var anySucceeded: Bool { goal.succeeded || message.succeeded }
    var summary: String { "Goal: \(goal.description) | Continue: \(message.description)" }

    /// A Goal failure never gates the independent message attempt.
    @MainActor static func run(goal: () async throws -> ResumeStep,
                              message: () async throws -> Void) async -> ResumeAttempts {
        let goalResult: ResumeStep
        do { goalResult = try await goal() }
        catch { goalResult = .failed(error.localizedDescription) }
        let messageResult: ResumeStep
        do { try Task.checkCancellation(); try await message(); messageResult = .succeeded }
        catch { messageResult = .failed(error.localizedDescription) }
        return ResumeAttempts(goal: goalResult, message: messageResult)
    }
    /// Retry the entire Goal + message sequence, not just focus acquisition.
    @MainActor static func repeating(
        maxAttempts: Int = 3,
        delayNanoseconds: UInt64 = 5_000_000_000,
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        previouslyDelivered: () async throws -> Bool,
        log: (String) -> Void,
        attempt: (Int) async -> ResumeAttempts
    ) async throws -> ResumeAttempts {
        precondition(maxAttempts > 0)
        var goalConfirmed = false
        var last = ResumeAttempts(goal: .skipped("not attempted"), message: .skipped("not attempted"))
        for number in 1...maxAttempts {
            try Task.checkCancellation()
            if number > 1 {
                log("Retry waiting \(delayNanoseconds / 1_000_000_000)s before full attempt \(number)/\(maxAttempts)")
                try await sleep(delayNanoseconds)
                do {
                    if try await previouslyDelivered() {
                        log("Previous message delivery confirmed before retry; no duplicate sent")
                        return ResumeAttempts(goal: goalConfirmed ? .succeeded : last.goal, message: .succeeded)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { log("Previous delivery recheck failed: \(error.localizedDescription); proceeding with next attempt") }
            }
            log("Full resume attempt \(number)/\(maxAttempts)")
            last = await attempt(number)
            goalConfirmed = goalConfirmed || last.goal.succeeded
            log("Attempt \(number)/\(maxAttempts): \(last.summary)")
            if last.message.succeeded { break }
        }
        return ResumeAttempts(goal: goalConfirmed ? .succeeded : last.goal, message: last.message)
    }

}
