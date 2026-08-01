import SwiftUI

/// Spec §19.8: counts SwiftUI body evaluations per key so tests can assert
/// that the teleprompter does not invalidate while the meter updates.
/// Compiled in DEBUG only; shipping targets must not include it.
#if DEBUG
enum RenderCounter {
    nonisolated(unsafe) static var counts: [String: Int] = [:]
}

extension View {
    func countRenders(_ key: String) -> some View {
        RenderCounter.counts[key, default: 0] += 1
        return self
    }
}
#endif
