import Foundation
import VoxglassRing

/// Lock-free single-producer / single-consumer ring buffer for the capture
/// path (spec §7.2, Studio Spec §4.11). The audio tap (real-time thread) is
/// the single producer; the writer task is the single consumer. All index
/// traffic lives behind C `_Atomic` load/store with release/acquire ordering,
/// so `push` performs no allocation and never blocks — the tap body keeps the
/// real-time discipline CI reviews for (no allocation, no lock, no `Task`,
/// no `os_log`, no wall-clock reads).
///
/// Usable capacity is `capacity - 1`. When the consumer falls behind, the
/// producer drops the samples that do not fit and counts them in
/// `droppedSampleCount` rather than blocking the real-time thread.
public final class CaptureRingBuffer: @unchecked Sendable {
    private var ring: vgr_ring
    private let capacityValue: Int

    /// Allocates a ring of the given capacity. `capacity` must be at least 2;
    /// a smaller request yields a ring with zero usable capacity.
    public init(capacity: Int) {
        self.capacityValue = max(capacity, 2)
        self.ring = vgr_create(size_t(max(capacity, 2)))
    }

    deinit {
        vgr_destroy(&ring)
    }

    /// The allocated capacity (usable capacity is one less).
    public var capacity: Int { capacityValue }

    /// Samples currently available to the consumer.
    public var availableSampleCount: Int {
        Int(vgr_available(&ring))
    }

    /// Samples dropped by the producer since creation because the consumer
    /// fell behind. Non-zero means the writer task cannot keep up.
    public var droppedSampleCount: Int {
        Int(vgr_dropped(&ring))
    }

    /// Producer side (real-time thread). Copies as many samples as fit,
    /// wrapping at the end of the ring; drops the rest.
    public func push(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        vgr_push(&ring, base, size_t(samples.count))
    }

    /// Consumer side (writer task). Copies up to `buffer.count` samples out,
    /// returning the number copied.
    public func pop(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        return Int(vgr_pop(&ring, base, size_t(buffer.count)))
    }
}
