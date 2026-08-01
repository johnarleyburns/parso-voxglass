import Foundation
import Testing
import VoxglassCore

/// Golden vectors: committed WAV fixtures + checked-in expected gains (RG 1.0
/// reference values produced by Tools/ReplayGainGoldenVectors/generate_vectors.py,
/// an independent Python transcription of the published algorithm). CI does not
/// need flac/metaflac. Every assertion here is an absolute value, not a property.
struct ReplayGainGoldenVectorTests {

    struct Expected: Decodable {
        let pink14dbfs: Double
        let pink20dbfs: Double
        let pink26dbfs: Double
        let tone1khz20dbfs: Double
        let tone100hz20dbfs: Double
        let sixtyPercentSilence: Double

        enum CodingKeys: String, CodingKey {
            case pink14dbfs = "pink-14dbfs"
            case pink20dbfs = "pink-20dbfs"
            case pink26dbfs = "pink-26dbfs"
            case tone1khz20dbfs = "tone-1khz-20dbfs"
            case tone100hz20dbfs = "tone-100hz-20dbfs"
            case sixtyPercentSilence = "sixty-percent-silence"
        }
    }

    private static func fixtureDir() throws -> URL {
        guard let jsonURL = Bundle.module.url(forResource: "expected", withExtension: "json", subdirectory: "ReplayGain") else {
            throw NSError(domain: "ReplayGainGoldenVectorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing ReplayGain/expected.json in test bundle"])
        }
        return jsonURL
    }

    private static func loadExpected() throws -> Expected {
        let jsonURL = try fixtureDir()
        let data = try Data(contentsOf: jsonURL)
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    private static func readWAV(_ name: String) throws -> (samples: [Float], sampleRate: Double) {
        let url = try fixtureDir().deletingLastPathComponent().appendingPathComponent("\(name).wav")
        let data = try Data(contentsOf: url)
        guard data.count > 44 else {
            throw NSError(domain: "ReplayGainGoldenVectorTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name).wav is not a valid WAV"])
        }
        let sampleRate = Double(data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) })
        let dataBytes = data.withUnsafeBytes { $0.load(fromByteOffset: 40, as: UInt32.self) }
        var samples: [Float] = []
        samples.reserveCapacity(Int(dataBytes) / 2)
        var offset = 44
        while offset + 1 < data.count {
            let v = Int16(bitPattern: data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt16.self) })
            samples.append(Float(v) / 32768.0)
            offset += 2
        }
        return (samples, sampleRate)
    }

    @Test func pinkAtMinus20dBFS_matchesReference() throws {
        let (samples, rate) = try Self.readWAV("pink-20dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let expected = try Self.loadExpected().pink20dbfs
        #expect(abs(gain - expected) < 0.25, "pink −20 dBFS: got \(gain), expected \(expected)")
    }

    @Test func pinkAtMinus14dBFS_matchesReference() throws {
        let (samples, rate) = try Self.readWAV("pink-14dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let expected = try Self.loadExpected().pink14dbfs
        #expect(abs(gain - expected) < 0.25, "pink −14 dBFS: got \(gain), expected \(expected)")
    }

    @Test func pinkAtMinus26dBFS_matchesReference() throws {
        let (samples, rate) = try Self.readWAV("pink-26dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let expected = try Self.loadExpected().pink26dbfs
        #expect(abs(gain - expected) < 0.25, "pink −26 dBFS: got \(gain), expected \(expected)")
    }

    @Test func oneKHzTone_matchesReference() throws {
        let (samples, rate) = try Self.readWAV("tone-1khz-20dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let expected = try Self.loadExpected().tone1khz20dbfs
        #expect(abs(gain - expected) < 0.25, "1 kHz −20 dBFS: got \(gain), expected \(expected)")
    }

    @Test func hundredHzTone_matchesReference() throws {
        let (samples, rate) = try Self.readWAV("tone-100hz-20dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let expected = try Self.loadExpected().tone100hz20dbfs
        #expect(abs(gain - expected) < 0.25, "100 Hz −20 dBFS: got \(gain), expected \(expected)")
    }

    @Test func sixtyPercentSilence_matchesReference() throws {
        let (samples, rate) = try Self.readWAV("sixty-percent-silence")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let expected = try Self.loadExpected().sixtyPercentSilence
        #expect(abs(gain - expected) < 0.25, "60 % silence: got \(gain), expected \(expected)")
    }

    @Test func hundredHzToneGetsAtLeastFiveDecibelsMoreGainThanOneKHz() throws {
        let (lowSamples, lowRate) = try Self.readWAV("tone-100hz-20dbfs")
        let (highSamples, highRate) = try Self.readWAV("tone-1khz-20dbfs")
        let gainLow = ReplayGainCalculator.analyze(samples: lowSamples, sampleRate: lowRate)
        let gainHigh = ReplayGainCalculator.analyze(samples: highSamples, sampleRate: highRate)
        #expect(gainLow - gainHigh >= 5.0)
    }

    @Test func pinkNoiseAbsoluteLevel() throws {
        let (samples, rate) = try Self.readWAV("pink-20dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        #expect(gain > -1.0 && gain < 5.0, "pink −20 dBFS must land in a sane band, got \(gain)")
    }

    @Test func perceivedVolumeForQuietTakeLandsInWarningBand() throws {
        let (samples, rate) = try Self.readWAV("pink-26dbfs")
        let gain = ReplayGainCalculator.analyze(samples: samples, sampleRate: rate)
        let perceived = 89.0 - gain
        #expect(perceived > 75.0 && perceived < 90.0, "perceived volume \(perceived) out of band")
    }

    @Test func truePeakNeverBelowPeakForFixtures() throws {
        for name in ["pink-20dbfs", "tone-1khz-20dbfs", "tone-100hz-20dbfs"] {
            let (samples, _) = try Self.readWAV(name)
            let peak = AudioMetricsCalculator.computePeak(samples)
            let truePeak = AudioMetricsCalculator.computeTruePeak(samples)
            #expect(truePeak >= peak - 0.01, "\(name): truePeak \(truePeak) < peak \(peak)")
        }
    }
}
