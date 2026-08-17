import Foundation
import Observation
import VoxglassCore

@Observable @MainActor
public final class RecordingMeter {
    public private(set) var peakDBFS: Float = -120
    public private(set) var rmsDBFS: Float = -120
    public private(set) var isClipping = false
    public private(set) var waveform: [Float] = []
    public private(set) var elapsed: TimeInterval = 0

    public init() {}

    func update(from levels: CaptureLevels) {
        peakDBFS = levels.peakDBFS
        rmsDBFS = levels.rmsDBFS
        isClipping = levels.isClipping
        elapsed = levels.sampleTime

        if waveform.count >= 600 {
            waveform.removeFirst(waveform.count - 599)
        }
        waveform.append(levels.peakDBFS)
    }

    func reset() {
        peakDBFS = -120
        rmsDBFS = -120
        isClipping = false
        waveform.removeAll()
        elapsed = 0
    }
}
