import AVFoundation
import Foundation

// MARK: - Ring atomics
//
// The app targets macOS 14, where the stdlib `Synchronization.Atomic` is not
// available. OSAtomic (deprecated but still shipped) provides real atomics
// with no allocation and no locking — the render-thread tap is allowed
// nothing else (spec §11.2 rule 3). Every operation here is a single aligned
// atomic access.
//
// This used to also back a hand-rolled `CaptureRingBuffer`; that ring is
// superseded by Core's lock-free C-atomics ring over the `VoxglassRing`
// target (U-7) and was deleted in U0. `RingAtomic` survives because
// `CaptureLevelAccumulator` — the render-thread level meter, a distinct
// concern from the ring — still needs it.
enum RingAtomic {
    @inline(__always)
    static func load(_ pointer: UnsafeMutablePointer<Int64>) -> Int64 {
        OSAtomicAdd64Barrier(0, pointer) // atomic read
    }

    @inline(__always)
    static func add(_ delta: Int64, _ pointer: UnsafeMutablePointer<Int64>) -> Int64 {
        OSAtomicAdd64Barrier(delta, pointer)
    }

    @inline(__always)
    static func store(_ value: Int64, _ pointer: UnsafeMutablePointer<Int64>) {
        let current = OSAtomicAdd64Barrier(0, pointer)
        _ = OSAtomicCompareAndSwap64Barrier(current, value, pointer)
    }

    @inline(__always)
    static func load32(_ pointer: UnsafeMutablePointer<Int32>) -> Int32 {
        OSAtomicAdd32Barrier(0, pointer) // atomic read
    }

    /// Max-store: publishes `value` if it is greater than the current value.
    @inline(__always)
    static func maxStore(_ value: Int32, _ pointer: UnsafeMutablePointer<Int32>) {
        while true {
            let current = OSAtomicAdd32Barrier(0, pointer)
            if value <= current { return }
            if OSAtomicCompareAndSwap32Barrier(current, value, pointer) { return }
        }
    }

    @inline(__always)
    static func store32(_ value: Int32, _ pointer: UnsafeMutablePointer<Int32>) {
        let current = OSAtomicAdd32Barrier(0, pointer)
        _ = OSAtomicCompareAndSwap32Barrier(current, value, pointer)
    }
}

// MARK: - CaptureLevelAccumulator
//
// Render-thread level metering with atomics only. Peak is stored as its bit
// pattern; the sum of squares is 16-bit fixed point so RMS is exact to
// ~0.001 dB at meter scale without floating-point atomics. A 4-hour take at
// 48 kHz accumulates ~4.5e13 in fixed point — well inside Int64.
final class CaptureLevelAccumulator: @unchecked Sendable {
    private let peakBits = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let rmsFixed = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let frameCount = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    private let clipping = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    init() {
        peakBits.initialize(to: 0)
        rmsFixed.initialize(to: 0)
        frameCount.initialize(to: 0)
        clipping.initialize(to: 0)
    }

    deinit {
        peakBits.deallocate()
        rmsFixed.deallocate()
        frameCount.deallocate()
        clipping.deallocate()
    }

    /// Producer side (render thread): pure arithmetic, no allocation, no lock.
    func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = data[0]

        var peak: Float = 0
        var rmsAcc: Int64 = 0
        var clip = false
        for i in 0..<frames {
            let s = samples[i]
            let a = abs(s)
            if a > peak { peak = a }
            rmsAcc &+= Int64(Double(s) * Double(s) * 65536)
            if a >= 0.999 { clip = true }
        }
        if peak > 0 {
            RingAtomic.maxStore(Int32(bitPattern: peak.bitPattern), peakBits)
        }
        _ = RingAtomic.add(rmsAcc, rmsFixed)
        _ = RingAtomic.add(Int64(frames), frameCount)
        if clip {
            RingAtomic.store32(1, clipping)
        }
    }

    /// Consumer side (poller / finalize): reads the atomic snapshot.
    func snapshot() -> (peak: Float, rms: Float, clipping: Bool, frameCount: Int64) {
        let peak = Float(bitPattern: UInt32(bitPattern: RingAtomic.load32(peakBits)))
        let fixed = RingAtomic.load(rmsFixed)
        let frames = RingAtomic.load(frameCount)
        let rms: Double = frames > 0 ? sqrt(Double(fixed) / 65536.0 / Double(frames)) : 0
        return (peak, Float(rms), RingAtomic.load32(clipping) != 0, frames)
    }

    func reset() {
        RingAtomic.store32(0, peakBits)
        RingAtomic.store(0, rmsFixed)
        RingAtomic.store(0, frameCount)
        RingAtomic.store32(0, clipping)
    }
}
