import AVFoundation
import VoxglassCore

public struct AVMetricsCalculator: AudioMetricsCalculating {
    public static let analyzerVersion = 1

    private let decoder: AVAudioDecoder

    public init(decoder: AVAudioDecoder = AVAudioDecoder()) {
        self.decoder = decoder
    }

    public func metrics(for url: URL) async throws -> AudioQualityMetrics {
        let decoded = try await decodeFileForImport(url)
        return AudioMetricsCalculator(decoder: PlaceholderAudioDecoder()).metrics(for: decoded.samples, sampleRate: decoded.sampleRate, channels: 1)
    }

    public func metrics(for samples: [Float], sampleRate: Double, channels: Int) -> AudioQualityMetrics {
        AudioMetricsCalculator(decoder: PlaceholderAudioDecoder()).metrics(for: samples, sampleRate: sampleRate, channels: channels)
    }

    /// Decodes any AVFoundation-readable file to mono Float samples. Shared by
    /// the metrics URL path and the Import Audio feature (§11.5). Sample rates
    /// outside ReplayGain's 44.1/48 kHz tables are resampled to 48 kHz so a
    /// rate table is never silently misapplied (§11.6.8 deviation note).
    public func decodeFileForImport(_ url: URL) async throws -> DecodedAudio {
        let format = try await decoder.describe(url)
        let target: Double? = ReplayGainCoefficients.supportedRates.contains(Int(format.sampleRate))
            ? nil
            : 48_000
        return try await decoder.decodeToMonoFloat(url, targetSampleRate: target)
    }
}
