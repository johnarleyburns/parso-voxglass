import Foundation
import ParsoAudioCore

/// High-quality mono float resampling, shared by every decoder in the encoder
/// pipeline (§16.3). Backed by `ParsoAudioCore.SampleRateConverter`
/// (libsamplerate SINC_BEST) — deterministic and portable, unlike the
/// OS-version-dependent `AVAudioConverter` it replaced.
///
/// Resampling is *not* decode: FLAC files are still decoded to PCM by libFLAC
/// before this runs, so the "FLAC decode goes through libFLAC" rule is
/// unaffected.
enum AudioResampler {

    /// Resample `input` (mono) from `inputRate` to `outputRate`.
    static func resample(_ input: [Float], from inputRate: Double, to outputRate: Double) throws -> [Float] {
        guard inputRate > 0, outputRate > 0 else { throw ResampleError.conversionUnavailable }
        if abs(inputRate - outputRate) < 0.5 || input.isEmpty { return input }

        let source = PCMBuffer(
            format: AudioFormat(sampleRate: inputRate, channelCount: 1),
            capacity: input.count
        )
        let channel = source.channel(0)
        for i in 0..<input.count { channel[i] = input[i] }

        do {
            let converter = SampleRateConverter(from: inputRate, to: outputRate, channels: 1, quality: .best)
            let converted = try converter.convert(source)
            let out = converted.channel(0)
            var result = [Float](repeating: 0, count: converted.frameCount)
            for i in 0..<converted.frameCount { result[i] = out[i] }
            return result
        } catch {
            throw ResampleError.conversionUnavailable
        }
    }

    enum ResampleError: Error {
        case conversionUnavailable
    }
}
