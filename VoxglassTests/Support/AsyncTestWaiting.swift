/// Polls `condition` instead of sleeping a fixed duration: a fixed sleep can
/// elapse before an async effect lands on a contended CI runner (false
/// failure) or elapse too early (false pass). Returns as soon as `condition`
/// is true, or after one final check at the timeout.
///
/// `@MainActor`-isolated because every caller's `condition` closure captures
/// `@MainActor` state (the coordinator/engine test doubles); a nonisolated
/// free function would require "sending" that non-Sendable closure across
/// isolation domains, which Swift 6 strict concurrency rejects.
@MainActor
@discardableResult
func waitUntil(_ condition: () -> Bool, timeoutNanoseconds: UInt64 = 5_000_000_000) async -> Bool {
    let step: UInt64 = 20_000_000
    var waited: UInt64 = 0
    while waited < timeoutNanoseconds {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: step)
        waited += step
    }
    return condition()
}

/// Last resort for a fire-and-forget MainActor task with no observable
/// milestone to poll for. Prefer `waitUntil` whenever the next assertion
/// names a concrete condition.
@MainActor
func drainMainQueue() async {
    try? await Task.sleep(nanoseconds: 200_000_000)
}
