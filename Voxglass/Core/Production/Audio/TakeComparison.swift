import Foundation

/// A/B comparison of two takes for one paragraph (spec §9.5, mockup 08).
///
/// The two takes are played at matched loudness using the ReplayGain values
/// already computed on each take; the quieter take is presented with the dB
/// that would be applied to it at playback. Selecting a take is a project
/// mutation, so this is phone-only — the watch never renders it.
public struct TakeComparison: Sendable, Equatable {
    /// One side of the comparison as the UI presents it.
    public struct Side: Sendable, Equatable, Identifiable {
        public var id: UUID { takeID }
        public var takeID: UUID
        public var label: String
        public var isSelected: Bool
        public var isArchived: Bool
        public var recordedAt: Date
        public var routeClass: CaptureRouteClass?
        public var duration: TimeInterval
        public var peakDBFS: Double?
        public var rmsDBFS: Double?
        public var noiseFloorDBFS: Double?
        public var replayGainDB: Double?

        public init(
            takeID: UUID,
            label: String,
            isSelected: Bool,
            isArchived: Bool,
            recordedAt: Date,
            routeClass: CaptureRouteClass? = nil,
            duration: TimeInterval,
            peakDBFS: Double? = nil,
            rmsDBFS: Double? = nil,
            noiseFloorDBFS: Double? = nil,
            replayGainDB: Double? = nil
        ) {
            self.takeID = takeID
            self.label = label
            self.isSelected = isSelected
            self.isArchived = isArchived
            self.recordedAt = recordedAt
            self.routeClass = routeClass
            self.duration = duration
            self.peakDBFS = peakDBFS
            self.rmsDBFS = rmsDBFS
            self.noiseFloorDBFS = noiseFloorDBFS
            self.replayGainDB = replayGainDB
        }
    }

    public var takeA: Side
    public var takeB: Side
    /// The gain, in dB, applied at playback to `gainAppliedToTakeID` so the two
    /// takes are heard at the same perceived loudness (§9.5). Zero when the
    /// takes already match (or ReplayGain is unavailable).
    public var matchedLoudnessGainDB: Double
    /// The take that receives the matched-loudness gain at playback.
    public var gainAppliedToTakeID: UUID

    public init(takeA: Side, takeB: Side) {
        self.takeA = takeA
        self.takeB = takeB

        // ReplayGain is the gain to reach reference loudness: lower is louder.
        // To make X match Y, apply (rgX − rgY) dB to X; only the quieter take
        // receives a positive boost, so the two never double-apply.
        var gain = 0.0
        var appliedTo: UUID = takeA.takeID
        if let rgA = takeA.replayGainDB, let rgB = takeB.replayGainDB {
            let boostA = rgA - rgB
            if boostA > 0 {
                gain = boostA
                appliedTo = takeA.takeID
            } else {
                gain = rgB - rgA
                appliedTo = takeB.takeID
            }
        }
        self.matchedLoudnessGainDB = gain
        self.gainAppliedToTakeID = appliedTo
    }
}
