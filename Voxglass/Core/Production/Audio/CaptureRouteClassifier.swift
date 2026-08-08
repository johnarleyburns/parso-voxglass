import Foundation

/// The route-readiness class produced by `CaptureRouteClassifier` (spec §7.1).
///
/// - `retailReady`: USB or wired route with stable sample rate, sufficient
///   input level, and a passing noise-floor target. No warnings.
/// - `communityReady`: acceptable for LibriVox / Internet Archive but misses a
///   retail threshold; retail export shows a warning.
/// - `draftOnly`: Bluetooth or built-in route, high latency, or a failed
///   noise-floor target; retail export shows a blocking-strength warning while
///   LibriVox / Internet Archive stay unaffected.
///
/// Bluetooth is never blocked — the classification tells the truth at export
/// time, it does not refuse to record (§7.1).
public enum CaptureRouteClass: String, Codable, Sendable, CaseIterable {
    case retailReady
    case communityReady
    case draftOnly

    /// Ordering for downgrade logic: `retailReady` is the least severe and
    /// `draftOnly` the most. `max` on two classes yields the worse one.
    public var severityRank: Int {
        switch self {
        case .retailReady: return 0
        case .communityReady: return 1
        case .draftOnly: return 2
        }
    }
}

/// Pure classifier for the capture route (spec §7.1). Thresholds for the
/// retail band are imported from the ACX `DestinationProfile` — never
/// restated here (§3).
public struct CaptureRouteClassifier {

    /// Input latency above this (seconds) marks a route `draftOnly`:
    /// high-latency routes cannot hit a retail quality target.
    public static let highInputLatencySeconds: TimeInterval = 0.1

    /// Classifies a route snapshot.
    ///
    /// The transport decides the base class, then measurements and properties
    /// can only downgrade it:
    /// - Bluetooth → `draftOnly`; USB → `retailReady`; wired headset, built-in
    ///   mic, AirPlay, and unknown → `communityReady` (matches mockup 06b).
    /// - High latency or a failed noise-floor target → `draftOnly`.
    /// - Unstable sample rate, a room-test peak over the retail ceiling, or a
    ///   speech RMS outside the retail band → at most `communityReady`.
    public static func classify(_ info: CaptureRouteInfo) -> CaptureRouteClass {
        var result: CaptureRouteClass
        if info.transports.contains(.bluetooth) {
            result = .draftOnly
        } else if info.transports.contains(.usb) {
            result = .retailReady
        } else {
            result = .communityReady
        }

        if info.inputLatencySeconds > highInputLatencySeconds {
            result = .draftOnly
        }

        let acx = DestinationProfile.acx
        if let noiseFloor = info.measuredNoiseFloorDBFS,
           let ceiling = acx.noiseFloorCeilingDBFS,
           noiseFloor > ceiling {
            result = .draftOnly
        }

        if !info.isSampleRateStable {
            result = max(result, .communityReady)
        }

        if let peak = info.measuredPeakDBFS,
           let ceiling = acx.peakCeilingDBFS,
           peak > ceiling {
            result = max(result, .communityReady)
        }

        if let speech = info.measuredSpeechRMSDBFS,
           case .rmsWindow(let minDBFS, let maxDBFS, _)? = acx.loudness,
           !(minDBFS <= speech && speech <= maxDBFS) {
            result = max(result, .communityReady)
        }

        return result
    }

    /// A user-facing label for the class, used by the route chip and the audio
    /// setup screen. Not localized in this MVP.
    public static func label(for klass: CaptureRouteClass) -> String {
        switch klass {
        case .retailReady: return "Retail-ready"
        case .communityReady: return "Community-ready"
        case .draftOnly: return "Draft only"
        }
    }
}

private func max(_ lhs: CaptureRouteClass, _ rhs: CaptureRouteClass) -> CaptureRouteClass {
    lhs.severityRank >= rhs.severityRank ? lhs : rhs
}
