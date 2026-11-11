import AVFoundation
import Foundation
import Testing
import VoxglassWatchCore

@Suite struct WatchAACAssetValidatorTests {
    private func dir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("aacval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func acceptsRealNonemptyAacM4A() throws {
        let url = try dir().appendingPathComponent("ok.m4a")
        try writeRealAAC(to: url)
        try WatchAACAssetValidator.validate(url)
    }

    @Test func rejectsUtf8BytesNamedM4A() throws {
        let url = try dir().appendingPathComponent("bad.m4a")
        try Data("aac".utf8).write(to: url)
        #expect(throws: WatchAACAssetValidationError.wrongCodec) { try WatchAACAssetValidator.validate(url) }
    }

    @Test func rejectsEmptyM4A() throws {
        let url = try dir().appendingPathComponent("empty.m4a")
        try Data().write(to: url)
        #expect(throws: WatchAACAssetValidationError.wrongCodec) { try WatchAACAssetValidator.validate(url) }
    }

    @Test func rejectsNonM4AExtensionBeforeOpening() throws {
        let d = try dir()
        let good = d.appendingPathComponent("ok.m4a"); try writeRealAAC(to: good)
        let caf = d.appendingPathComponent("ok.caf")
        try FileManager.default.copyItem(at: good, to: caf)
        #expect(throws: WatchAACAssetValidationError.wrongContainer) { try WatchAACAssetValidator.validate(caf) }
        let missing = d.appendingPathComponent("missing.caf")
        #expect(throws: WatchAACAssetValidationError.wrongContainer) { try WatchAACAssetValidator.validate(missing) }
    }

    @Test func errorDescriptionsAreStableAndDistinct() {
        let all: [WatchAACAssetValidationError] = [.wrongContainer, .emptyAudio, .wrongCodec]
        let texts = all.compactMap(\.errorDescription)
        #expect(texts.count == 3 && Set(texts).count == 3)
    }
}
