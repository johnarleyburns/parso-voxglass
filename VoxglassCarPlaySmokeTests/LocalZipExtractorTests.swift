import Foundation
import XCTest
import ZIPFoundation
@testable import Voxglass

// pure unit test: no app launch
final class LocalZipExtractorTests: XCTestCase {
    func testExtractsSmallDeflatedArchive() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxglass-zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let audio = Data(repeating: 0x5a, count: 32 * 1024)
        let chapters = "00:00:00.000 Chapter One\n"
        let audioURL = fixtureRoot.appendingPathComponent("sample.m4a")
        let chaptersURL = fixtureRoot.appendingPathComponent("chapters.txt")
        try audio.write(to: audioURL)
        try chapters.write(to: chaptersURL, atomically: true, encoding: .utf8)

        let archiveURL = fixtureRoot.appendingPathComponent("fixture.zip")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "book/sample.m4a", fileURL: audioURL, compressionMethod: .deflate)
        try archive.addEntry(with: "book/chapters.txt", fileURL: chaptersURL, compressionMethod: .deflate)

        let extracted = try LocalZipExtractor.extract(archiveURL)
        defer { try? FileManager.default.removeItem(at: extracted) }

        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("book/sample.m4a")), audio)
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("book/chapters.txt"), encoding: .utf8),
            chapters
        )
    }
}
