import AVFoundation
import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport
@testable import VoxglassStudioKit

/// Spec §11.6.8 deviation note + T1d: rates outside the ReplayGain tables are
/// resampled to 48 kHz before analysis — never silently analyzed at the wrong
/// rate.
@Suite struct AVMetricsCalculatorTests {

    private func writeWAV(at url: URL, sampleRate: Int, toneFrames: Int) throws {
        var data = Data(capacity: 44 + toneFrames * 2)
        func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let dataSize = toneFrames * 2
        append(Array("RIFF".utf8)); le32(UInt32(36 + dataSize))
        append(Array("WAVE".utf8))
        append(Array("fmt ".utf8)); le32(16); le16(1); le16(1); le32(UInt32(sampleRate)); le32(UInt32(sampleRate * 2)); le16(2); le16(16)
        append(Array("data".utf8)); le32(UInt32(dataSize))
        for i in 0..<toneFrames {
            let v = Int16((0.3 * sin(2 * .pi * 440.0 * Double(i) / Double(sampleRate)) * 32767.0).rounded())
            le16(UInt16(bitPattern: v))
        }
        try data.write(to: url)
    }

    @Test func unsupportedRateIsResampledTo48kHz() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("tone-96k.wav")
        try writeWAV(at: url, sampleRate: 96_000, toneFrames: 96_000 * 2)

        let decoded = try await AVMetricsCalculator().decodeFileForImport(url)
        #expect(decoded.sampleRate == 48_000)
        #expect(abs(decoded.duration - 2.0) < 0.05)

        let metrics = try await AVMetricsCalculator().metrics(for: url)
        #expect(metrics.replayGainDB.isFinite, "resampled analysis must produce a finite RG gain")
        #expect(metrics.sampleRate == 48_000)
        #expect(abs(metrics.peakDBFS - (-10.46)) < 0.5)
    }

    @Test func supportedRateIsNotResampled() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("tone-44k1.wav")
        try writeWAV(at: url, sampleRate: 44_100, toneFrames: 44_100)

        let decoded = try await AVMetricsCalculator().decodeFileForImport(url)
        #expect(decoded.sampleRate == 44_100)
    }

    @Test func concreteAVAudioDecoderConformsToProtocol() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voxglass-metrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("tone-48k.wav")
        try writeWAV(at: url, sampleRate: 48_000, toneFrames: 48_000)

        let decoder = AVAudioDecoder()
        let described = try await decoder.describe(url)
        #expect(described.sampleRate == 48_000)
        #expect(described.channels == 1)
        #expect(described.codec == "pcm")

        let decoded = try await decoder.decodeToMonoFloat(url, targetSampleRate: nil)
        #expect(decoded.sampleRate == 48_000)
        #expect(abs(decoded.duration - 1.0) < 0.01)
        #expect(decoded.samples.count == 48_000)

        let resampled = try await decoder.decodeToMonoFloat(url, targetSampleRate: 44_100)
        #expect(resampled.sampleRate == 44_100)
        #expect(abs(resampled.duration - 1.0) < 0.05)
    }
}
