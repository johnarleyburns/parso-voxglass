import Foundation
import Observation
import VoxglassCore

/// A main-actor adapter that translates Observation invalidation into a
/// callback. Used by CarPlay to rebuild templates when tracked coordinator
/// properties change, without observing fast clocks like `playhead`.
@MainActor
final class ObservationSubscription {
    private var cancelled = false
    private let track: () -> Void
    private let onChange: () -> Void

    init(
        track: @escaping () -> Void,
        onChange: @escaping () -> Void
    ) {
        self.track = track
        self.onChange = onChange
        arm()
    }

    private func arm() {
        guard !cancelled else { return }

        withObservationTracking {
            track()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.cancelled else { return }

                self.onChange()
                self.arm()
            }
        }
    }

    func cancel() {
        cancelled = true
    }

    deinit {
        cancelled = true
    }
}
