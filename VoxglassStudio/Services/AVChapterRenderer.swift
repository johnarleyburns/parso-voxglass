import AVFoundation
import Foundation
import VoxglassCore

/// Concrete `ChapterRenderable` backed by AVFoundation (spec §12.4).
///
/// Renders a chapter's segments into a single lossless CAF/PCM file at the
/// plan's output format. Each take is decoded, resampled to the output rate,
/// trimmed to its `trim` range, gain/fade applied sample-wise, and written
/// with the configured silence buffers between paragraphs. The returned
/// `ChapterRendering.paragraphOffsets` is what makes "seek to ¶ 218" work on a
/// rendered file and is persisted by the caller.
public struct AVChapterRenderer: ChapterRenderable {
    public let assets: any ContentAddressedStore

    public init(assets: any ContentAddressedStore) {
        self.assets = assets
    }

    public func render(
        _ plan: RenderPlan,
        to url: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ChapterRendering {
        let rate = plan.outputFormat.sampleRate ?? 48_000
        let channels = plan.outputFormat.channels ?? 1

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let output = try AVAudioFile(forWriting: url, settings: settings)
        let format = output.processingFormat
        var cursor: AVAudioFramePosition = 0
        var offsets: [UUID: Range<TimeInterval>] = [:]

        for (index, segment) in plan.segments.enumerated() {
            try Task.checkCancellation()
            progress(Double(index) / Double(max(1, plan.segments.count)))

            try writeSilence(seconds: segment.leadingSilence, format: format, to: output, cursor: &cursor)

            let startTime = Double(cursor) / rate
            let audioSeconds = try await writeSegment(segment, rate: rate, format: format, to: output, cursor: &cursor)
            offsets[segment.paragraphID] = startTime..<(startTime + audioSeconds)

            try writeSilence(seconds: segment.trailingSilence, format: format, to: output, cursor: &cursor)
        }

        progress(1)

        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ref = AudioAssetReference(
            sha256: try SHA256Hex.hex(contentsOf: url),
            relativePath: url.lastPathComponent,
            byteCount: byteCount,
            contentType: "audio/caf"
        )
        return ChapterRendering(
            ref: ref,
            duration: Double(cursor) / rate,
            paragraphOffsets: offsets
        )
    }

    // MARK: - Segment writing

    private func writeSegment(
        _ segment: PlaybackSegment,
        rate: Double,
        format: AVAudioFormat,
        to output: AVAudioFile,
        cursor: inout AVAudioFramePosition
    ) async throws -> TimeInterval {
        let url = assets.url(for: segment.assetRef)
        let file = try AVAudioFile(forReading: url)
        let fileFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount) else {
            throw AVChapterRendererError.bufferAllocation
        }
        try file.read(into: fileBuffer)

        var samples = try decodeToMonoFloat(fileBuffer, from: fileFormat, targetRate: rate)

        let startSample = max(0, min(samples.count, Int(segment.trim.lowerBound * rate)))
        let endSample = max(startSample, min(samples.count, Int(segment.trim.upperBound * rate)))
        var trimmed = Array(samples[startSample..<endSample])
        samples.removeAll(keepingCapacity: false)

        let gain = Float(pow(10, segment.gainDB / 20))
        let fadeInFrames = max(1, Int(segment.fadeIn * rate))
        let fadeOutFrames = max(1, Int(segment.fadeOut * rate))
        for i in trimmed.indices {
            var g = gain
            if i < fadeInFrames { g *= Float(i) / Float(fadeInFrames) }
            let fromEnd = trimmed.count - i
            if fromEnd <= fadeOutFrames { g *= Float(fromEnd) / Float(fadeOutFrames) }
            trimmed[i] *= g
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(trimmed.count)) else {
            throw AVChapterRendererError.bufferAllocation
        }
        buffer.frameLength = AVAudioFrameCount(trimmed.count)
        if let data = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                for i in trimmed.indices {
                    data[c][i] = trimmed[i]
                }
            }
        }

        try output.write(from: buffer)
        cursor += AVAudioFramePosition(buffer.frameLength)
        return Double(buffer.frameLength) / rate
    }

    private func writeSilence(
        seconds: TimeInterval,
        format: AVAudioFormat,
        to output: AVAudioFile,
        cursor: inout AVAudioFramePosition
    ) throws {
        let frames = AVAudioFrameCount(max(0, seconds) * format.sampleRate)
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AVChapterRendererError.bufferAllocation
        }
        buffer.frameLength = frames
        if let data = buffer.floatChannelData {
            for c in 0..<Int(format.channelCount) {
                for i in 0..<Int(frames) {
                    data[c][i] = 0
                }
            }
        }
        try output.write(from: buffer)
        cursor += AVAudioFramePosition(buffer.frameLength)
    }

    /// Decode a buffer of any format/channel count to a Float32 mono array at
    /// the target sample rate.
    private func decodeToMonoFloat(
        _ buffer: AVAudioPCMBuffer,
        from format: AVAudioFormat,
        targetRate: Double
    ) throws -> [Float] {
        let outASBD = AudioStreamBasicDescription(
            mSampleRate: targetRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var outASBDMut = outASBD
        guard let outFormat = AVAudioFormat(streamDescription: &outASBDMut),
              let converter = AVAudioConverter(from: format, to: outFormat) else {
            throw AVChapterRendererError.conversionUnavailable
        }

        let input = buffer
        let box = ConversionBox(buffer: input)
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if let b = box.buffer {
                box.buffer = nil
                status.pointee = .haveData
                return b
            }
            status.pointee = .noDataNow
            return nil
        }

        let ratio = targetRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AVChapterRendererError.bufferAllocation
        }

        var result: [Float] = []
        var error: NSError?
        var done = false
        while !done {
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if let data = outBuffer.floatChannelData {
                for i in 0..<Int(outBuffer.frameLength) {
                    result.append(data[0][i])
                }
            }
            switch status {
            case .endOfStream:
                done = true
            case .error:
                throw error ?? AVChapterRendererError.conversionFailed
            default:
                if outBuffer.frameLength == 0 { done = true }
            }
        }
        return result
    }

    private final class ConversionBox: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    }
}

public enum AVChapterRendererError: Error {
    case bufferAllocation
    case conversionUnavailable
    case conversionFailed
}
