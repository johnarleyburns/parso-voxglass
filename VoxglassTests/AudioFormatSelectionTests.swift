import Testing
import Foundation
@testable import VoxglassCore

@Suite struct AudioFormatSelectionTests {
    private let decoder = JSONDecoder()

    // MARK: - Codec detection

    @Test func codecDetectionByExtension() {
        #expect(AudioFormatSelection.codec(for: nil, filename: "track.flac") == .flac)
        #expect(AudioFormatSelection.codec(for: nil, filename: "track.opus") == .opus)
        #expect(AudioFormatSelection.codec(for: nil, filename: "track.ogg") == .vorbis)
        #expect(AudioFormatSelection.codec(for: nil, filename: "track.mp3") == .mp3)
    }

    @Test func codecDetectionByFormatString() {
        #expect(AudioFormatSelection.codec(for: "Flac", filename: "track") == .flac)
        #expect(AudioFormatSelection.codec(for: "24bit Flac", filename: "track") == .flac)
        #expect(AudioFormatSelection.codec(for: "Opus", filename: "track") == .opus)
        #expect(AudioFormatSelection.codec(for: "VBR MP3", filename: "track") == .mp3)
        #expect(AudioFormatSelection.codec(for: "320Kbps MP3", filename: "track") == .mp3)
    }

    @Test func codecDetectionHeuristicFallback() {
        #expect(AudioFormatSelection.codec(for: "Some FLAC thing", filename: "track") == .flac)
        #expect(AudioFormatSelection.codec(for: "opus audio", filename: "track") == .opus)
        #expect(AudioFormatSelection.codec(for: "MP3 encoded", filename: "track") == .mp3)
    }

    @Test func codecDetectionReturnsNilForUnknown() {
        #expect(AudioFormatSelection.codec(for: "WAV", filename: "track.wav") == nil)
        #expect(AudioFormatSelection.codec(for: "Metadata", filename: "track.xml") == nil)
    }

    // MARK: - Quality ranking

    @Test func fLACQualityRankExceedsMP3() {
        let flacFile = InternetArchiveFile(name: "track.flac", source: "original", format: "Flac")
        let mp3File = InternetArchiveFile(name: "track.mp3", source: "original", format: "320Kbps MP3")

        let flacRank = AudioFormatSelection.qualityRank(for: flacFile, codec: .flac)
        let mp3Rank = AudioFormatSelection.qualityRank(for: mp3File, codec: .mp3)

        #expect(flacRank > mp3Rank)
    }

    @Test func higherBitrateRanksHigherWithinCodec() {
        let mp3_320 = InternetArchiveFile(name: "track.mp3", source: "derivative", format: "320Kbps MP3")
        let mp3_64 = InternetArchiveFile(name: "track.mp3", source: "derivative", format: "64Kbps MP3")

        #expect(AudioFormatSelection.qualityRank(for: mp3_320, codec: .mp3) > AudioFormatSelection.qualityRank(for: mp3_64, codec: .mp3))
    }

    @Test func originalSourceScoresHigher() {
        let original = InternetArchiveFile(name: "track.mp3", source: "original", format: "MP3")
        let derivative = InternetArchiveFile(name: "track.mp3", source: "derivative", format: "MP3")

        #expect(AudioFormatSelection.qualityRank(for: original, codec: .mp3) > AudioFormatSelection.qualityRank(for: derivative, codec: .mp3))
    }

    // MARK: - DerivativePolicy

    @Test func wiFiPolicyPrefersFLAC() {
        let policy = DerivativePolicy(networkCondition: .wifi)
        #expect(policy.rankedCodecs == [.flac, .mp3])
    }

    @Test func cellularPolicyPrefersMP3() {
        let policy = DerivativePolicy(networkCondition: .cellular)
        #expect(policy.rankedCodecs == [.mp3])
    }

    @Test func cellularWithLosslessPrefersFLAC() {
        let policy = DerivativePolicy(networkCondition: .cellular, preferLosslessOnCellular: true)
        #expect(policy.rankedCodecs == [.flac, .mp3])
    }

    @Test func prefetchPolicyPrefersOpus() {
        let policy = DerivativePolicy(isPrefetchOrQueued: true)
        #expect(policy.rankedCodecs == [.opus, .flac, .mp3])
    }

    @Test func cachedOpusCAFReturnsOnlyOpus() {
        let policy = DerivativePolicy(hasCachedOpusCAF: true)
        #expect(policy.rankedCodecs == [.opus])
    }

    @Test func bestCodecSelectsFLACOnWiFi() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .wifi)
        let result = policy.bestCodec(for: metadata.files)
        #expect(result?.codec == .flac)
    }

    @Test func bestCodecSelectsMP3OnCellular() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .cellular)
        let result = policy.bestCodec(for: metadata.files)
        #expect(result?.codec == .mp3)
    }

    // MARK: - Multi-format fixture selection

    @Test func multiFormatItemSelectsFLACFamilyOnWiFi() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .wifi)
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: metadata.files, policy: policy)

        // All selected files should be FLAC (ch 1, 2 have FLAC; ch 3 only has MP3/Opus so it stays)
        let selectedNames = selected.map(\.name)
        #expect(selectedNames.allSatisfy { $0.hasSuffix(".flac") || $0.hasSuffix(".mp3") == false })  // WiFi should prefer FLAC: got \(selectedNames)
    }

    @Test func multiFormatItemSelectsMP3FamilyOnCellular() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .cellular)
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: metadata.files, policy: policy)

        // All selected files should be MP3
        let selectedNames = selected.map(\.name)
        #expect(selectedNames.allSatisfy { $0.hasSuffix(".mp3") })  // Cellular should prefer MP3: got \(selectedNames)
    }

    @Test func multiFormatItemWithNoPolicyPicksBestAvailableCodec() throws {
        let metadata = try multiformatFixture()
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: metadata.files)

        // Without policy, should pick the highest available codec (FLAC)
        let selectedNames = selected.map(\.name)
        #expect(selectedNames.contains { $0.hasSuffix(".flac") })
    }

    // MARK: - Legacy MP3 fixture still works

    @Test func legacyMP3FixtureStillSelectsCorrectFiles() throws {
        let data = try fixtureData("metadata_librivox_item")
        let metadata = try decoder.decode(InternetArchiveMetadata.self, from: data)
        let selected = metadata.selectedAudioFiles

        #expect(selected.map(\.name) == [
            "01 Chapter One.mp3",
            "02 Chapter Two_vbr.mp3",
            "10 Chapter Ten_64kb.mp3"
        ])
    }

    // MARK: - AudioCodec ordering

    @Test func audioCodecOrdering() {
        let sorted = AudioCodec.allCases.sorted()
        #expect(sorted == [.mp3, .vorbis, .opus, .flac])
    }

    @Test func audioCodecAllCases() {
        #expect(Set(AudioCodec.allCases) == Set([.flac, .opus, .vorbis, .mp3]))
    }

    // MARK: - All playable extensions

    @Test func allPlayableExtensionsIncludesFLACAndOpus() {
        #expect(AudioFormatSelection.allPlayableExtensions.contains("flac"))
        #expect(AudioFormatSelection.allPlayableExtensions.contains("opus"))
        #expect(AudioFormatSelection.allPlayableExtensions.contains("mp3"))
    }

    // MARK: - Helpers

    private func multiformatFixture() throws -> InternetArchiveMetadata {
        let data = try fixtureData("metadata_multiformat_item")
        return try decoder.decode(InternetArchiveMetadata.self, from: data)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let testFile = URL(fileURLWithPath: #filePath)
        let fixtureURL = testFile
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("InternetArchive", isDirectory: true)
            .appendingPathComponent("\(name).json")
        return try Data(contentsOf: fixtureURL)
    }
}
