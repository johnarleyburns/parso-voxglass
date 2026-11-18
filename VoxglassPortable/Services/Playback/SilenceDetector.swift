import Foundation

/// Pure RMS-window silence detector (P2-2). Requires `N` consecutive silent
/// windows to enter `.silent`, exits immediately on speech. No AVFoundation.
public final class SilenceDetector {
    public enum State { case speech, silent }

    public private(set) var state: State = .speech
    private let threshold: Float
    private let consecutiveFramesRequired: Int
    private var silentCount = 0

    public init(threshold: Float = 0.02, consecutiveFramesRequired: Int = 5) {
        self.threshold = threshold
        self.consecutiveFramesRequired = consecutiveFramesRequired
    }

    /// Feed in the RMS of a buffer. Returns the new state.
    @discardableResult
    public func process(rms: Float) -> State {
        if rms < threshold {
            silentCount += 1
            if silentCount >= consecutiveFramesRequired {
                state = .silent
            }
        } else {
            silentCount = 0
            state = .speech
        }
        return state
    }

    public func reset() {
        silentCount = 0
        state = .speech
    }
}
