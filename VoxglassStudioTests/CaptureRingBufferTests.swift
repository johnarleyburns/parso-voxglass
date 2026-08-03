import AVFoundation
import Foundation
import Testing
import VoxglassCore
@testable import VoxglassStudioKit

/// WP-D ring buffer: SPSC correctness, wraparound, and overrun accounting
/// (§11.2 rule 4). The tap discipline ("no allocation, no lock, no dispatch")
/// is a code-review property and is asserted by the file's structure, not by
/// a runtime test — but the ring's observable contract is tested here.
@Suite struct CaptureRingBufferTests {

    private func makeBuffer(_ frames: Int, value: Float, sampleRate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = buffer.floatChannelData![0]
        for i in 0..<frames { data[i] = value }
        return buffer
    }

    @Test func writerStarvationCountsOverrunsWithoutLosingFramesThatFit() {
        let ring = CaptureRingBuffer(capacityFrames: 4_096)
        ring.reset()

        // 5 chunks of 2048 frames: 2 fit, the 3rd overruns, and the consumer
        // only drains after — the frames that fit must be intact.
        for _ in 0..<5 {
            ring.write(makeBuffer(2_048, value: 0.5))
        }

        #expect(ring.overrunCount() >= 3, "three of five chunks must overrun a 4096-frame ring")
        #expect(ring.framesAvailable() == 4_096, "the ring must hold what fits")

        // Drain everything: the first 4096 written frames are preserved.
        var scratch = [Float](repeating: 0, count: 4_096)
        let count = ring.drain(into: &scratch, maxFrames: 4_096)
        #expect(count == 4_096)
        #expect(scratch.allSatisfy { $0 == 0.5 })
        #expect(ring.framesAvailable() == 0)
    }

    @Test func wraparoundIsCorrect() {
        let ring = CaptureRingBuffer(capacityFrames: 1_024)
        ring.reset()

        // Fill past the physical end repeatedly so the mask wraps, then drain
        // and verify the exact sequence order (values are the frame index).
        for block in 0..<20 {
            let buffer = makeBuffer(256, value: 0)
            let data = buffer.floatChannelData![0]
            for i in 0..<256 { data[i] = Float(block * 256 + i) }
            ring.write(buffer)
        }

        var scratch = [Float](repeating: 0, count: 4_096)
        let count = ring.drain(into: &scratch, maxFrames: 4_096)
        #expect(count == 1_024)
        for i in 0..<count {
            #expect(scratch[i] == Float(i), "drain must preserve the write order across wraparound at index \(i)")
        }
    }

    @Test func drainChunksMatchSource() {
        let ring = CaptureRingBuffer(capacityFrames: 8_192)
        ring.reset()

        let total = 3_000
        let buffer = makeBuffer(total, value: 0)
        let data = buffer.floatChannelData![0]
        for i in 0..<total { data[i] = Float(i) }
        ring.write(buffer)

        // Drain in odd-sized chunks; the concatenation must equal the source.
        var out: [Float] = []
        var scratch = [Float](repeating: 0, count: 1_000)
        while true {
            let n = ring.drain(into: &scratch, maxFrames: 1_000)
            if n == 0 { break }
            out.append(contentsOf: scratch[0..<n])
        }
        #expect(out.count == total)
        for i in 0..<total {
            #expect(out[i] == Float(i))
        }
    }

    @Test func resetClearsEverything() {
        let ring = CaptureRingBuffer(capacityFrames: 1_024)
        ring.reset()
        ring.write(makeBuffer(512, value: 1))
        ring.reset()
        #expect(ring.framesAvailable() == 0)
        #expect(ring.overrunCount() == 0)
    }
}
