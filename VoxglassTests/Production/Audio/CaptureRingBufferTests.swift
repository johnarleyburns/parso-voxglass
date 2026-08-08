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
    /// yields between pushes so the consumer can always keep up, which is what
    /// the real writer task does (it drains as fast as the tap produces).
    @Test func concurrentProducerConsumerPreservesOrderAndCount() async throws {
        let ring = CaptureRingBuffer(capacity: 8192)
        let total = 65_536
        let chunkSize = 64

        final class Box: @unchecked Sendable {
            var received = 0
            var mismatches = 0
            var lastValue = -1
        }
        let box = Box()

        let consumer = Task.detached {
            var buffer = [Float](repeating: 0, count: chunkSize)
            while box.received < total {
                let n = buffer.withUnsafeMutableBufferPointer { ring.pop(into: $0) }
                if n == 0 {
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
                samples.withUnsafeBufferPointer { ring.push($0) }
                await Task.yield()
            }
        }

        await producer.value
        let deadline = ContinuousClock.now + .seconds(10)
        while box.received < total {
            if ContinuousClock.now > deadline {
                break
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        await consumer.value

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
