@preconcurrency import AVFoundation
import Foundation

/// High-quality mono float resampling via `AVAudioConverter` (the system SRC),
/// shared by every decoder in the encoder pipeline (§16.3). Resampling is
/// *not* decode: FLAC files are still decoded to PCM by libFLAC before this
/// runs, so the "FLAC decode goes through libFLAC" rule is unaffected.
enum AudioResampler {

    private final class InputState: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var delivered = false

        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    /// Resample `input` from `inputRate` to `outputRate`.
    static func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false
        )!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ResampleError.conversionUnavailable
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
        all.reserveCapacity(Int(Double(input.count) * ratio) + 4096)
        var error: NSError?
        // Deliver the whole input buffer once, then signal end of stream on
        // every later pull. Returning the same buffer with .haveData each time
        // makes AVAudioConverter re-consume it forever, which never lets the
        // converter reach the end and grows `all` without bound.
        let inputState = InputState(buffer: inputBuffer)

        while true {
            let status = converter.convert(to: outputBuffer, error: &error) { _, packetStatus in
                guard !inputState.delivered else {
                    packetStatus.pointee = .endOfStream
                    return nil
                }
                inputState.delivered = true
                packetStatus.pointee = .haveData
                return inputState.buffer
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
                // The converter consumed all input; drain whatever it produced
                // (the resampling filter tail) before stopping.
                if let channel = outputBuffer.floatChannelData?[0] {
                    all.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
                }
                return all
            @unknown default:
                return all
            }
        }
    }

    enum ResampleError: Error {
        case conversionUnavailable
    }
}
