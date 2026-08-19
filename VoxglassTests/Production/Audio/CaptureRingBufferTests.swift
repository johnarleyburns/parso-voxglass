import Foundation
import Testing
import VoxglassCore

/// Lock-free SPSC correctness for `CaptureRingBuffer` (spec §7.2): a real-time
/// producer and a writer-task consumer must never reorder, duplicate, or lose
/// samples while the consumer keeps up, and the producer must drop (never
/// block) when the consumer falls behind.
@Suite struct CaptureRingBufferTests {

    @Test func pushPopRoundTripsInOrder() {
        let ring = CaptureRingBuffer(capacity: 1024)
        let input: [Float] = [1, 2, 3, 4, 5]
        input.withUnsafeBufferPointer { ring.push($0) }
        #expect(ring.availableSampleCount == 5)
        var output = [Float](repeating: -1, count: 5)
        let n = output.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
        #expect(n == 5)
        #expect(output == input)
        #expect(ring.availableSampleCount == 0)
    }

    @Test func usableCapacityIsOneLessThanAllocated() {
        let ring = CaptureRingBuffer(capacity: 4)
        let input: [Float] = [1, 2, 3, 4, 5, 6]
        input.withUnsafeBufferPointer { ring.push($0) }
        // capacity 4 -> 3 usable slots; the 4th push is dropped.
        #expect(ring.availableSampleCount == 3)
        #expect(ring.droppedSampleCount == 3)
        var output = [Float](repeating: -1, count: 4)
        let n = output.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
        #expect(n == 3)
        #expect(Array(output[0..<3]) == [1, 2, 3])
    }

    @Test func wrapsAroundCapacityWithoutLoss() {
        let ring = CaptureRingBuffer(capacity: 16)
        // Push 20 in two chunks (wraps at 15 usable), drain fully, then push
        // more and confirm the tail is intact and contiguous.
        let first = (0..<20).map { Float($0) }
        first.withUnsafeBufferPointer { ring.push($0) }
        #expect(ring.availableSampleCount == 15)
        var a = [Float](repeating: -1, count: 15)
        _ = a.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
        #expect(Array(a) == (0..<15).map { Float($0) })

        let second: [Float] = [100, 101, 102, 103]
        second.withUnsafeBufferPointer { ring.push($0) }
        var b = [Float](repeating: -1, count: 4)
        let n = b.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
        #expect(n == 4)
        #expect(Array(b) == second)
    }

    /// The load-bearing property: a concurrent producer and consumer preserve
    /// the exact sample sequence with no gaps or duplicates. The producer
    /// waits for room before each push, which is what makes "no drops" a
    /// precondition rather than a scheduling accident.
    ///
    /// Every wait here is bounded. An earlier version let the consumer spin on
    /// `while box.received < total` and then blocked on `await consumer.value`,
    /// so a single dropped chunk parked the whole suite forever — invisible on
    /// CI, where swift-testing block-buffers stdout and a hung run logs nothing
    /// at all.
    @Test func concurrentProducerConsumerPreservesOrderAndCount() async throws {
        let capacity = 8192
        let ring = CaptureRingBuffer(capacity: capacity)
        let total = 65_536
        let chunkSize = 64
        let deadline = ContinuousClock.now + .seconds(30)

        final class Box: @unchecked Sendable {
            var received = 0
            var mismatches = 0
            var lastValue = -1
            var produced = false
        }
        let box = Box()

        let consumer = Task.detached {
            var buffer = [Float](repeating: 0, count: chunkSize)
            while box.received < total {
                let n = buffer.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
                if n == 0 {
                    // Nothing left and nothing more coming, or we are out of
                    // time: stop instead of spinning forever.
                    if box.produced || ContinuousClock.now > deadline { break }
                    try? await Task.sleep(for: .microseconds(50))
                    continue
                }
                for i in 0..<n {
                    let value = Int(buffer[i])
                    if value != box.lastValue + 1 {
                        box.mismatches += 1
                    }
                    box.lastValue = value
                }
                box.received += n
            }
        }

        let producer = Task.detached {
            var samples = [Float](repeating: 0, count: chunkSize)
            for start in stride(from: 0, to: total, by: chunkSize) {
                for i in 0..<chunkSize { samples[i] = Float(start + i) }
                // Usable capacity is one less than allocated. Yield until the
                // chunk fits so the ring never drops; on a starved runner the
                // deadline lets the push through and the expectations below
                // report the overrun instead of hanging.
                while ring.availableSampleCount + chunkSize > capacity - 1 {
                    if ContinuousClock.now > deadline { break }
                    await Task.yield()
                }
                samples.withUnsafeBufferPointer { ring.push($0) }
                await Task.yield()
            }
            box.produced = true
        }

        await producer.value
        await consumer.value

        #expect(ring.droppedSampleCount == 0, "the producer must not overrun a consumer that is keeping up")
        #expect(box.received == total)
        #expect(box.mismatches == 0)
        #expect(box.lastValue == total - 1)
    }

    @Test func tinyCapacityIsClampedToAUsableRing() {
        // The wrapper clamps a sub-2 request to a minimal usable ring rather
        // than producing a zero-capacity buffer.
        let ring = CaptureRingBuffer(capacity: 1)
        #expect(ring.availableSampleCount == 0)
        let input: [Float] = [7]
        input.withUnsafeBufferPointer { ring.push($0) }
        #expect(ring.availableSampleCount == 1)
        var output = [Float](repeating: -1, count: 1)
        let n = output.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
        #expect(n == 1)
        #expect(output == [7])
    }
}
