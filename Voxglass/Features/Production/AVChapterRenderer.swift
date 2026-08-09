import AVFoundation
import Foundation
import VoxglassCore
import VoxglassEncoders

/// Materializes a `RenderPlan` into a lossless CAF file on iPhone (spec
/// §12.4). The shipping implementation of the `ChapterRenderable` seam: decodes
/// each take through `RoutingAudioDecoder`, applies the plan's trims, gain,
/// fades, and leading/trailing silence, and writes the assembled mono PCM to
/// disk.
///
/// Cancellation (spec §11.2, M-4): the render checks `Task` cancellation once
/// per segment, so a long chapter can be cancelled cleanly mid-run; the
/// `ChunkedRenderCoordinator` then resumes at the first incomplete chapter.
public struct AVChapterRenderer: ChapterRenderable {
    /// Root of the `.voxproject` package; segment asset references resolve
    /// against it.
    public let assetsRoot: URL
    public let decoder: any AudioDecoding

    public init(assetsRoot: URL, decoder: any AudioDecoding = RoutingAudioDecoder()) {
        self.assetsRoot = assetsRoot
        self.decoder = decoder
    }

    public func render(
        _ plan: RenderPlan,
        to url: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ChapterRendering {
        let rate = plan.outputFormat.sampleRate ?? 44_100
        var samples: [Float] = []
        var offsets: [UUID: Range<TimeInterval>] = [:]
        let total = max(1, plan.segments.count)

        for (index, segment) in plan.segments.enumerated() {
            try Task.checkCancellation()

            let sourceURL = assetsRoot.appendingPathComponent(segment.assetRef.relativePath)
            let decoded = try await decoder.decodeToMonoFloat(sourceURL, targetSampleRate: rate)

            var segmentSamples = apply(plan: segment, decoded: decoded, rate: rate)
            let offsetStart = Double(samples.count) / rate
            let offsetEnd = offsetStart + Double(segmentSamples.count) / rate
            offsets[segment.paragraphID] = offsetStart..<offsetEnd

            samples.append(contentsOf: segmentSamples)
            segmentSamples.removeAll(keepingCapacity: true)

            progress(Double(index + 1) / Double(total))
        }

        try Task.checkCancellation()
        try writeCAF(samples, sampleRate: rate, to: url)

        let sha = try SHA256Hex.hex(contentsOf: url)
        return ChapterRendering(
            ref: AudioAssetReference(
                sha256: sha,
                relativePath: url.lastPathComponent,
                byteCount: samples.count * 4,
                contentType: "audio/caf"
            ),
            duration: Double(samples.count) / rate,
            paragraphOffsets: offsets
        )
    }

    /// Applies leading/trailing silence, trim, gain, and fades to one take's
    /// decoded PCM, producing the sample run this segment contributes.
    private func apply(plan segment: PlaybackSegment, decoded: DecodedAudio, rate: Double) -> [Float] {
        var out: [Float] = []

        let leading = Int(segment.leadingSilence * rate)
        if leading > 0 {
            out.append(contentsOf: [Float](repeating: 0, count: leading))
        }

        let low = Int(segment.trim.lowerBound * rate)
        let high = min(decoded.samples.count, Int(segment.trim.upperBound * rate))
        let gain = pow(10.0, segment.gainDB / 20.0)
        let fadeInFrames = Int(segment.fadeIn * rate)
        let fadeOutFrames = Int(segment.fadeOut * rate)
        let count = max(0, high - low)

        if count > 0 {
            out.reserveCapacity(out.count + count)
            for i in 0..<count {
                var sample = decoded.samples[low + i] * Float(gain)
                if fadeInFrames > 0, i < fadeInFrames {
                    sample *= Float(i) / Float(fadeInFrames)
                }
                if fadeOutFrames > 0, count - i <= fadeOutFrames {
                    sample *= Float(count - i) / Float(fadeOutFrames)
                }
                out.append(sample)
            }
        }

        let trailing = Int(segment.trailingSilence * rate)
        if trailing > 0 {
            out.append(contentsOf: [Float](repeating: 0, count: trailing))
        }

        return out
    }

    private func writeCAF(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
    }
}
