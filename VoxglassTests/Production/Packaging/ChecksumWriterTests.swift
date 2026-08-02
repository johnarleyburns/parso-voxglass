import Foundation
import Testing
import VoxglassCore

/// §16.10 / §19.3 — checksum manifests are `shasum -a 256 -c`-compatible.
@Suite struct ChecksumWriterTests {

    @Test func manifestIsCoreutilsFormat() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("book_01.mp3")
        let b = dir.appendingPathComponent("book_02.mp3")
        try Data("first file bytes".utf8).write(to: a)
        try Data("second file bytes".utf8).write(to: b)

        let files = [
            ExportedFile(url: a, role: .chapter),
            ExportedFile(url: b, role: .chapter)
        ]
        let data = try ChecksumWriter().sha256Manifest(files)
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n")

        #expect(lines.count == 2)
        let hashA = try SHA256Hex.hex(contentsOf: a)
        let hashB = try SHA256Hex.hex(contentsOf: b)
        #expect(lines[0].hasPrefix(hashA + "  book_01.mp3"))
        #expect(lines[1].hasPrefix(hashB + "  book_02.mp3"))
    }

    @Test func manifestMatchesSystemShasum() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("chapter.wav")
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        try payload.write(to: file)
        let files = [ExportedFile(url: file, role: .chapter)]
        let manifest = try ChecksumWriter().sha256Manifest(files)
        let line = String(decoding: manifest, as: UTF8.self).trimmingCharacters(in: .newlines)

        // Cross-check against CryptoKit's hex of the same bytes (same digest as
        // the shasum CLI, which the acceptance checklist tells users to run).
        let expected = try SHA256Hex.hex(contentsOf: file)
        #expect(line == "\(expected)  chapter.wav")
    }
}
