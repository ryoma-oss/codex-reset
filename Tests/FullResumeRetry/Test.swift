import Foundation
@main struct Tests {
    @MainActor static func main() async throws {
        var attempts: [Int] = [], waits: [UInt64] = []
        let third = try await ResumeAttempts.repeating(sleep: { waits.append($0) }, previouslyDelivered: { false }, log: { _ in }, attempt: { number in
            attempts.append(number)
            return ResumeAttempts(goal: number == 1 ? .succeeded : .skipped("already active"), message: number == 3 ? .succeeded : .failed("not sent"))
        })
        precondition(attempts == [1, 2, 3] && waits == [5_000_000_000, 5_000_000_000])
        precondition(third.goal.succeeded && third.message.succeeded)
        attempts = []; waits = []
        let immediate = try await ResumeAttempts.repeating(sleep: { waits.append($0) }, previouslyDelivered: { false }, log: { _ in }, attempt: { number in
            attempts.append(number); return ResumeAttempts(goal: .skipped("no Goal"), message: .succeeded)
        })
        precondition(immediate.message.succeeded && attempts == [1] && waits.isEmpty)
        attempts = []; waits = []
        let delayed = try await ResumeAttempts.repeating(sleep: { waits.append($0) }, previouslyDelivered: { true }, log: { _ in }, attempt: { number in
            attempts.append(number); return ResumeAttempts(goal: .succeeded, message: .failed("not yet confirmed"))
        })
        precondition(delayed.message.succeeded && attempts == [1] && waits.count == 1)
        attempts = []; waits = []
        let failed = try await ResumeAttempts.repeating(sleep: { waits.append($0) }, previouslyDelivered: { false }, log: { _ in }, attempt: { number in
            attempts.append(number); return ResumeAttempts(goal: .failed("missing button"), message: .failed("focus failed"))
        })
        precondition(!failed.anySucceeded && attempts == [1, 2, 3] && waits.count == 2)
        print("PASS: full sequence retried three times with 5s intervals; success stops; late delivery avoids resend; failed attempts bounded; earlier Goal success preserved")
    }
}
