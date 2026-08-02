import AVFoundation
import Foundation
import VoxglassCore

/// AVFoundation-backed `AudioDecoding` for the encoder pipeline (§16.2). Reads
/// any AVFoundation-supported file (CAF, WAV, MP3, FLAC, M4A) into mono float
/// PCM, optionally resampling to a target rate via `AVAudioConverter`.
public struct AVFoundationDecoder: AudioDecoding {

    public init() {}

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let codec: String
        switch format.settings[AVFormatIDKey] as? UInt32 {
        case kAudioFormatLinearPCM: codec = "pcm"
        case kAudioFormatMPEG4AAC: codec = "aac"
        case kAudioFormatAppleLossless: codec = "alac"
        case kAudioFormatMPEGLayer3: codec = "mp3"
        default: codec = "unknown"
        }
        return AudioFormatDescription(
            sampleRate: format.sampleRate,
            channels: Int(format.channelCount),
            bitDepth: format.settings[AVLinearPCMBitDepthKey] as? Int,
            codec: codec
        )
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AVAudioDecoderError.bufferAllocationFailed
        }
        try file.read(into: buffer)

        var samples = monoFloat(from: buffer)
        var rate = format.sampleRate

        if let targetSampleRate, abs(targetSampleRate - rate) > 0.5 {
            samples = try resample(samples, from: rate, to: targetSampleRate)
            rate = targetSampleRate
        }

        return DecodedAudio(samples: samples, sampleRate: rate, duration: Double(buffer.frameLength) / format.sampleRate)
    }

    // MARK: - Conversion

    private func monoFloat(from buffer: AVAudioPCMBuffer) -> [Float] {
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else {
            return []
        }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frameLength))
        }
        var mono = [Float](repeating: 0, count: frameLength)
        for c in 0..<channels {
            let channel = UnsafeBufferPointer(start: data[c], count: frameLength)
            for i in 0..<frameLength { mono[i] += channel[i] / Float(channels) }
        }
        return mono
    }

    private func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AVAudioDecoderError.conversionUnavailable
        }
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(input.count))!
        inputBuffer.frameLength = AVAudioFrameCount(input.count)
        if let channel = inputBuffer.floatChannelData?[0] {
            input.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: input.count)
            }
        }

        let ratio = outputRate / inputRate
        let outputCapacity = AVAudioFrameCount(Double(input.count) * ratio) + 4096
        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity)!

        var all: [Float] = []
        var error: NSError?

        while true {
            let status = converter.convert(to: outputBuffer, error: &error) { _, packetStatus in
                packetStatus.pointee = .haveData
                return inputBuffer
            }
            switch status {
            case .haveData:
                if let channel = outputBuffer.floatChannelData?[0] {
                    all.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
                }
            case .endOfStream:
                if let channel = outputBuffer.floatChannelData?[0] {
                    all.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
                }
                return all
            case .inputRanDry, .error:
                // The block always supplies the full input buffer, so "ran dry"
                // only signals the converter finished consuming it; treat both
                // as a hard stop rather than looping forever.
                return all
            @unknown default:
                return all
            }
        }
    }

    public enum AVAudioDecoderError: Error {
        case bufferAllocationFailed
        case conversionUnavailable
        case conversionFailed
    }
}
