import Foundation
import Testing
import VoxglassCore

/// P7 (§13.4): the iPhone shares export packages as a single `.zip`. This
/// parses the produced archive structurally — end-of-central-directory, central
/// directory entries, and each stored local entry with matching sizes and
/// content — proving the zip is well-formed without any third-party archive
/// framework.
@Suite struct ExportPackageZipperTests {

    @Test func zipRoundTripsFilesStructurally() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = directory.appendingPathComponent("ready_01_chapter.mp3")
        let b = directory.appendingPathComponent("ready_02_chapter.flac")
        let c = directory.appendingPathComponent("checksums.sha256")
        try Data(repeating: 0xAB, count: 2_048).write(to: a)
        try Data("filename  sha256\n".utf8).write(to: c)
        // Non-zero content so CRC is meaningful.
        var flacBytes = Data((0..<5_000).map { UInt8(($0 * 7 + 3) & 0xFF) })
        try flacBytes.write(to: b)

        let output = directory.appendingPathComponent("package.zip")
        let zipped = try ExportPackageZipper.zipContents(of: directory, to: output)
        let zipData = try Data(contentsOf: zipped)

        // ── End of central directory: 3 entries.
        let eocd = try #require(zipEOCD(zipData))
        #expect(eocd.entryCount == 3)

        // ── Central directory: names, sizes, and local offsets.
        let central = centralDirectoryEntries(zipData, eocd: eocd)
        let names = Set(central.map(\.name))
        #expect(names == ["ready_01_chapter.mp3", "ready_02_chapter.flac", "checksums.sha256"])

        let byName = Dictionary(uniqueKeysWithValues: central.map { ($0.name, $0) })
        for entry in byName.values {
            let local = try #require(localEntry(zipData, offset: entry.localHeaderOffset))
            #expect(local.name == entry.name)
            #expect(local.compressedSize == entry.compressedSize)
            #expect(local.uncompressedSize == entry.uncompressedSize)
            let source = try Data(contentsOf: directory.appendingPathComponent(entry.name))
            #expect(Int(local.uncompressedSize) == source.count)
            let payload = zipData.subdata(in: Int(local.dataOffset)..<Int(local.dataOffset + UInt64(local.uncompressedSize)))
            #expect(payload == source)
        }
    }

    // MARK: - Minimal zip reader

    private struct EOCD {
        let entryCount: Int
        let centralOffset: Int
        let centralSize: Int
    }

    private struct CentralEntry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private struct LocalEntry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let dataOffset: UInt64
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        var value: UInt16 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<offset + 2) }
        return value
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<offset + 4) }
        return value
    }

    private func zipEOCD(_ data: Data) -> EOCD? {
        // Scan backward for the 0x06054b50 signature within the last 64 KB.
        let start = max(0, data.count - 65_535)
        for i in stride(from: data.count - 22, through: start, by: -1) where u32(data, i) == 0x0605_4b50 {
            let entryCount = Int(u16(data, i + 10))
            let centralSize = Int(u32(data, i + 12))
            let centralOffset = Int(u32(data, i + 16))
            return EOCD(entryCount: entryCount, centralOffset: centralOffset, centralSize: centralSize)
        }
        return nil
    }

    private func centralDirectoryEntries(_ data: Data, eocd: EOCD) -> [CentralEntry] {
        var entries: [CentralEntry] = []
        var offset = eocd.centralOffset
        for _ in 0..<eocd.entryCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4b50 else { return [] }
            let nameLength = Int(u16(data, offset + 28))
            let extraLength = Int(u16(data, offset + 30))
            let commentLength = Int(u16(data, offset + 32))
            let nameData = data[offset + 46 ..< offset + 46 + nameLength]
            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(CentralEntry(
                name: name,
                compressedSize: Int(u32(data, offset + 20)),
                uncompressedSize: Int(u32(data, offset + 24)),
                localHeaderOffset: Int(u32(data, offset + 42))
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private func localEntry(_ data: Data, offset: Int) -> LocalEntry? {
        guard offset + 30 <= data.count, u32(data, offset) == 0x0403_4b50 else { return nil }
        let nameLength = Int(u16(data, offset + 26))
        let extraLength = Int(u16(data, offset + 28))
        let nameData = data[offset + 30 ..< offset + 30 + nameLength]
        let name = String(decoding: nameData, as: UTF8.self)
        let compressedSize = Int(u32(data, offset + 18))
        let uncompressedSize = Int(u32(data, offset + 22))
        return LocalEntry(
            name: name,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            dataOffset: UInt64(offset + 30 + nameLength + extraLength)
        )
    }
}
