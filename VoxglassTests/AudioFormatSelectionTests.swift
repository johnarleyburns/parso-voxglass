import XCTest
@testable import VoxglassCore

final class AudioFormatSelectionTests: XCTestCase {
    private let decoder = JSONDecoder()

    // MARK: - Codec detection

    func testCodecDetectionByExtension() {
        XCTAssertEqual(AudioFormatSelection.codec(for: nil, filename: "track.flac"), .flac)
        XCTAssertEqual(AudioFormatSelection.codec(for: nil, filename: "track.opus"), .opus)
        XCTAssertEqual(AudioFormatSelection.codec(for: nil, filename: "track.ogg"), .vorbis)
        XCTAssertEqual(AudioFormatSelection.codec(for: nil, filename: "track.mp3"), .mp3)
    }

    func testCodecDetectionByFormatString() {
        XCTAssertEqual(AudioFormatSelection.codec(for: "Flac", filename: "track"), .flac)
        XCTAssertEqual(AudioFormatSelection.codec(for: "24bit Flac", filename: "track"), .flac)
        XCTAssertEqual(AudioFormatSelection.codec(for: "Opus", filename: "track"), .opus)
        XCTAssertEqual(AudioFormatSelection.codec(for: "VBR MP3", filename: "track"), .mp3)
        XCTAssertEqual(AudioFormatSelection.codec(for: "320Kbps MP3", filename: "track"), .mp3)
    }

    func testCodecDetectionHeuristicFallback() {
        XCTAssertEqual(AudioFormatSelection.codec(for: "Some FLAC thing", filename: "track"), .flac)
        XCTAssertEqual(AudioFormatSelection.codec(for: "opus audio", filename: "track"), .opus)
        XCTAssertEqual(AudioFormatSelection.codec(for: "MP3 encoded", filename: "track"), .mp3)
    }

    func testCodecDetectionReturnsNilForUnknown() {
        XCTAssertNil(AudioFormatSelection.codec(for: "WAV", filename: "track.wav"))
        XCTAssertNil(AudioFormatSelection.codec(for: "Metadata", filename: "track.xml"))
    }

    // MARK: - Quality ranking

    func testFLACQualityRankExceedsMP3() {
        let flacFile = InternetArchiveFile(name: "track.flac", source: "original", format: "Flac")
        let mp3File = InternetArchiveFile(name: "track.mp3", source: "original", format: "320Kbps MP3")

        let flacRank = AudioFormatSelection.qualityRank(for: flacFile, codec: .flac)
        let mp3Rank = AudioFormatSelection.qualityRank(for: mp3File, codec: .mp3)

        XCTAssertGreaterThan(flacRank, mp3Rank)
    }

    func testHigherBitrateRanksHigherWithinCodec() {
        let mp3_320 = InternetArchiveFile(name: "track.mp3", source: "derivative", format: "320Kbps MP3")
        let mp3_64 = InternetArchiveFile(name: "track.mp3", source: "derivative", format: "64Kbps MP3")

        XCTAssertGreaterThan(
            AudioFormatSelection.qualityRank(for: mp3_320, codec: .mp3),
            AudioFormatSelection.qualityRank(for: mp3_64, codec: .mp3)
        )
    }

    func testOriginalSourceScoresHigher() {
        let original = InternetArchiveFile(name: "track.mp3", source: "original", format: "MP3")
        let derivative = InternetArchiveFile(name: "track.mp3", source: "derivative", format: "MP3")

        XCTAssertGreaterThan(
            AudioFormatSelection.qualityRank(for: original, codec: .mp3),
            AudioFormatSelection.qualityRank(for: derivative, codec: .mp3)
        )
    }

    // MARK: - DerivativePolicy

    func testWiFiPolicyPrefersFLAC() {
        let policy = DerivativePolicy(networkCondition: .wifi)
        XCTAssertEqual(policy.rankedCodecs, [.flac, .mp3])
    }

    func testCellularPolicyPrefersMP3() {
        let policy = DerivativePolicy(networkCondition: .cellular)
        XCTAssertEqual(policy.rankedCodecs, [.mp3])
    }

    func testCellularWithLosslessPrefersFLAC() {
        let policy = DerivativePolicy(networkCondition: .cellular, preferLosslessOnCellular: true)
        XCTAssertEqual(policy.rankedCodecs, [.flac, .mp3])
    }

    func testPrefetchPolicyPrefersOpus() {
        let policy = DerivativePolicy(isPrefetchOrQueued: true)
        XCTAssertEqual(policy.rankedCodecs, [.opus, .flac, .mp3])
    }

    func testCachedOpusCAFReturnsOnlyOpus() {
        let policy = DerivativePolicy(hasCachedOpusCAF: true)
        XCTAssertEqual(policy.rankedCodecs, [.opus])
    }

    func testBestCodecSelectsFLACOnWiFi() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .wifi)
        let result = policy.bestCodec(for: metadata.files)
        XCTAssertEqual(result?.codec, .flac)
    }

    func testBestCodecSelectsMP3OnCellular() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .cellular)
        let result = policy.bestCodec(for: metadata.files)
        XCTAssertEqual(result?.codec, .mp3)
    }

    // MARK: - Multi-format fixture selection

    func testMultiFormatItemSelectsFLACFamilyOnWiFi() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .wifi)
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: metadata.files, policy: policy)

        // All selected files should be FLAC (ch 1, 2 have FLAC; ch 3 only has MP3/Opus so it stays)
        let selectedNames = selected.map(\.name)
        XCTAssertTrue(selectedNames.allSatisfy { $0.hasSuffix(".flac") || $0.hasSuffix(".mp3") == false },
                       "WiFi should prefer FLAC: got \(selectedNames)")
    }

    func testMultiFormatItemSelectsMP3FamilyOnCellular() throws {
        let metadata = try multiformatFixture()
        let policy = DerivativePolicy(networkCondition: .cellular)
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: metadata.files, policy: policy)

        // All selected files should be MP3
        let selectedNames = selected.map(\.name)
        XCTAssertTrue(selectedNames.allSatisfy { $0.hasSuffix(".mp3") },
                       "Cellular should prefer MP3: got \(selectedNames)")
    }

    func testMultiFormatItemWithNoPolicyPicksBestAvailableCodec() throws {
        let metadata = try multiformatFixture()
        let selected = InternetArchiveAudioSelector.selectedAudioFiles(from: metadata.files)

        // Without policy, should pick the highest available codec (FLAC)
        let selectedNames = selected.map(\.name)
        XCTAssertTrue(selectedNames.contains { $0.hasSuffix(".flac") })
    }

    // MARK: - Legacy MP3 fixture still works

    func testLegacyMP3FixtureStillSelectsCorrectFiles() throws {
        let data = try fixtureData("metadata_librivox_item")
        let metadata = try decoder.decode(InternetArchiveMetadata.self, from: data)
        let selected = metadata.selectedAudioFiles

        XCTAssertEqual(selected.map(\.name), [
            "01 Chapter One.mp3",
            "02 Chapter Two_vbr.mp3",
            "10 Chapter Ten_64kb.mp3"
        ])
    }

    // MARK: - AudioCodec ordering

    func testAudioCodecOrdering() {
        let sorted = AudioCodec.allCases.sorted()
        XCTAssertEqual(sorted, [.mp3, .vorbis, .opus, .flac])
    }

    func testAudioCodecAllCases() {
        XCTAssertEqual(Set(AudioCodec.allCases), Set([.flac, .opus, .vorbis, .mp3]))
    }

    // MARK: - All playable extensions

    func testAllPlayableExtensionsIncludesFLACAndOpus() {
        XCTAssertTrue(AudioFormatSelection.allPlayableExtensions.contains("flac"))
        XCTAssertTrue(AudioFormatSelection.allPlayableExtensions.contains("opus"))
        XCTAssertTrue(AudioFormatSelection.allPlayableExtensions.contains("mp3"))
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
