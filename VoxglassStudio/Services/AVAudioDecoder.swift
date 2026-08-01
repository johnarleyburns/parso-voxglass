import AVFoundation
import Foundation
import VoxglassCore

/// Concrete `AudioDecoding` implementation backed by AVFoundation (§4.2).
/// This is the live implementation behind `AudioMetricsCalculator.metrics(for:)`
/// in the Studio target; the Core `PlaceholderAudioDecoder` exists only so the
/// library target compiles without AVFoundation.
public struct AVAudioDecoder: AudioDecoding {
    public init() {}

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let codec: String
        switch format.settings[AVFormatIDKey] as? UInt32 ?? kAudioFormatLinearPCM {
        case kAudioFormatLinearPCM: codec = "pcm"
        case kAudioFormatMPEG4AAC: codec = "aac"
        case kAudioFormatAppleLossless: codec = "alac"
        case kAudioFormatMPEGLayer3: codec = "mp3"
        case kAudioFormatOpus: codec = "opus"
        default: codec = "unknown"
        }
        let bitDepth = format.streamDescription.pointee.mBitsPerChannel > 0
            ? Int(format.streamDescription.pointee.mBitsPerChannel)
            : nil
        return AudioFormatDescription(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            bitDepth: bitDepth,
            codec: codec
        )
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else {
            throw AVAudioDecoderError.noChannelData
        }
        let count = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: count)
        let chanCount = Int(format.channelCount)
        for i in 0..<count {
            var sum: Float = 0
            for c in 0..<chanCount {
                sum += channelData[c][i]
            }
            samples[i] = sum / Float(chanCount)
        }
        var sampleRate = format.sampleRate
        var duration = Double(frameCount) / sampleRate
        if let target = targetSampleRate, abs(target - sampleRate) > 0.5 {
            let resampled = try resampleTo(samples: samples, fromRate: sampleRate, targetRate: target)
            samples = resampled.samples
            sampleRate = resampled.sampleRate
            duration = Double(samples.count) / sampleRate
        }
        return DecodedAudio(samples: samples, sampleRate: sampleRate, duration: duration)
    }

    private func resampleTo(samples: [Float], fromRate: Double, targetRate: Double) throws -> (samples: [Float], sampleRate: Double) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: fromRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = inputBuffer.floatChannelData {
            for i in 0..<samples.count { dst[0][i] = samples[i] }
        }

        var outASBD = asbd
        outASBD.mSampleRate = targetRate
        guard let outFormat = AVAudioFormat(streamDescription: &outASBD),
              let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }

        let ratio = targetRate / fromRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }

        let box = InputBox(buffer: inputBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if let b = box.buffer, b.frameLength > 0 {
                let result = b
                box.buffer = nil
                outStatus.pointee = .haveData
                return result
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        var error: NSError?
        var done = false
        var outSamples: [Float] = []
        while !done {
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if let data = outBuffer.floatChannelData {
                for i in 0..<Int(outBuffer.frameLength) {
                    outSamples.append(data[0][i])
                }
            }
            switch status {
            case .endOfStream:
                done = true
            case .error:
                throw error ?? AVAudioDecoderError.bufferAllocationFailed
            default:
                if outBuffer.frameLength == 0 { done = true }
            }
        }
        return (outSamples, targetRate)
    }

    private final class InputBox: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(buffer: AVAudioPCMBuffer?) { self.buffer = buffer }
    }
}

public enum AVAudioDecoderError: Error {
    case bufferAllocationFailed
    case noChannelData
}
