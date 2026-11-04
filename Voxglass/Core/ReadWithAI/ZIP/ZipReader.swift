import Foundation
import Compression

public struct ZipEntry: Sendable {
    public let filename: String
    public let compressedSize: UInt32
    public let uncompressedSize: UInt32
    public let crc32: UInt32
    public let compressionMethod: UInt16
    public let localHeaderOffset: UInt32
    public let isDirectory: Bool
}

public enum ZipReaderError: Error {
    case notAZipFile
    case unsupportedCompression(UInt16)
    case fileTooLarge
    case dataCorrupt(String)
}

// MARK: - implementation-determinism-exempt: uses system randomness (Compression) and filesystem reads
public struct ZipReader: Sendable {
    /// Import limits protect the app from ZIP bombs and malformed archives.
    /// EPUB/DOCX are user-selected documents, so archive metadata is not
    /// trusted merely because the file came from the Files picker.
    public static let maxArchiveSize = 512 * 1024 * 1024
    public static let maxEntryCount = 4_096
    public static let maxEntryUncompressedSize = 128 * 1024 * 1024
    public static let maxTotalUncompressedSize = 1 * 1024 * 1024 * 1024
    public static let maxCompressionRatio = 1_000.0

    private let data: Data
    private let entries: [ZipEntry]

    public init(data: Data) throws {
        guard data.count <= Self.maxArchiveSize else {
            throw ZipReaderError.fileTooLarge
        }
        self.data = data
        let endRecord = try Self.findEndOfCentralDirectory(in: data)
        self.entries = try Self.readCentralDirectory(in: data, endRecord: endRecord)
    }

    public init(contentsOf url: URL) throws {
        if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > Self.maxArchiveSize {
            throw ZipReaderError.fileTooLarge
        }
        try self.init(data: try Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public var fileNames: [String] { entries.map(\.filename) }

    public func entry(named name: String) -> ZipEntry? {
        entries.first { $0.filename == name }
    }

    public func read(_ entry: ZipEntry) throws -> Data {
        guard let idx = entries.firstIndex(where: { $0.filename == entry.filename }) else {
            throw ZipReaderError.dataCorrupt("entry not found in directory: \(entry.filename)")
        }
        // Use the parsed entry, not a caller-supplied copy with potentially
        // inflated size/offset metadata.
        return try Self.extractFile(data: data, entry: entries[idx])
    }

    public func read(filename: String) throws -> Data {
        guard let entry = entry(named: filename) else {
            throw ZipReaderError.dataCorrupt("file not found: \(filename)")
        }
        return try read(entry)
    }

    // MARK: - Private parsing

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }.littleEndian
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian
    }

    private static func findEndOfCentralDirectory(in data: Data) throws -> (offset: Int, entryCount: UInt16, dirSize: UInt32, dirOffset: UInt32) {
        guard data.count >= 22 else { throw ZipReaderError.notAZipFile }
        let minSearch = max(0, data.count - 65557)
        for i in stride(from: data.count - 22, through: minSearch, by: -1) {
            if readUInt32(data, at: i) == 0x06054b50 {
                let entryCount = readUInt16(data, at: i + 10)
                let dirSize = readUInt32(data, at: i + 12)
                let dirOffset = readUInt32(data, at: i + 16)
                return (i, entryCount, dirSize, dirOffset)
            }
        }
        throw ZipReaderError.notAZipFile
    }

    private static func readCentralDirectory(in data: Data, endRecord: (offset: Int, entryCount: UInt16, dirSize: UInt32, dirOffset: UInt32)) throws -> [ZipEntry] {
        guard Int(endRecord.entryCount) <= Self.maxEntryCount else {
            throw ZipReaderError.fileTooLarge
        }

        var entries: [ZipEntry] = []
        var offset = Int(endRecord.dirOffset)
        guard offset <= data.count,
              Int(endRecord.dirSize) <= data.count - offset else {
            throw ZipReaderError.dataCorrupt("central directory out of bounds")
        }
        let limit = offset + Int(endRecord.dirSize)

        for _ in 0..<endRecord.entryCount {
            guard limit - offset >= 46 else {
                throw ZipReaderError.dataCorrupt("truncated central directory")
            }
            guard readUInt32(data, at: offset) == 0x02014b50 else {
                throw ZipReaderError.dataCorrupt("invalid central directory signature")
            }

            let compressionMethod = readUInt16(data, at: offset + 10)
            let crc32 = readUInt32(data, at: offset + 16)
            let compressedSize = readUInt32(data, at: offset + 20)
            let uncompressedSize = readUInt32(data, at: offset + 24)
            let filenameLen = Int(readUInt16(data, at: offset + 28))
            let extraLen = Int(readUInt16(data, at: offset + 30))
            let commentLen = Int(readUInt16(data, at: offset + 32))
            let localHeaderOffset = readUInt32(data, at: offset + 42)

            let recordLength = 46 + filenameLen + extraLen + commentLen
            guard recordLength <= limit - offset else {
                throw ZipReaderError.dataCorrupt("truncated central directory entry")
            }
            guard offset + recordLength <= data.count else {
                throw ZipReaderError.dataCorrupt("central directory entry out of bounds")
            }
            let filename = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + filenameLen)), encoding: .utf8)
                ?? ""
            let isDirectory = filename.hasSuffix("/")

            if !isDirectory {
                try validateEntrySize(compressedSize: compressedSize, uncompressedSize: uncompressedSize)
            }

            entries.append(ZipEntry(
                filename: filename,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc32,
                compressionMethod: compressionMethod,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory
            ))

            offset += recordLength
        }

        guard entries.count == Int(endRecord.entryCount), offset == limit else {
            throw ZipReaderError.dataCorrupt("central directory entry count mismatch")
        }
        let totalUncompressedSize = entries.reduce(into: 0) { total, entry in
            total += Int64(entry.uncompressedSize)
        }
        guard totalUncompressedSize <= Int64(Self.maxTotalUncompressedSize) else {
            throw ZipReaderError.fileTooLarge
        }
        return entries
    }

    private static func extractFile(data: Data, entry: ZipEntry) throws -> Data {
        if entry.isDirectory { return Data() }
        try validateEntrySize(compressedSize: entry.compressedSize, uncompressedSize: entry.uncompressedSize)

        var offset = Int(entry.localHeaderOffset)

        guard offset <= data.count, 30 <= data.count - offset else {
            throw ZipReaderError.dataCorrupt("local header out of bounds")
        }
        guard readUInt32(data, at: offset) == 0x04034b50 else {
            throw ZipReaderError.dataCorrupt("invalid local file header")
        }

        let filenameLen = Int(readUInt16(data, at: offset + 26))
        let extraLen = Int(readUInt16(data, at: offset + 28))
        let headerLength = 30 + filenameLen + extraLen
        guard headerLength <= data.count - offset else {
            throw ZipReaderError.dataCorrupt("local file header out of bounds")
        }
        offset += headerLength

        let compressedSize = Int(entry.compressedSize)
        guard compressedSize <= data.count - offset else {
            throw ZipReaderError.dataCorrupt("file data out of bounds")
        }

        let compressed = data.subdata(in: offset..<(offset + compressedSize))

        switch entry.compressionMethod {
        case 0:
            guard compressed.count == Int(entry.uncompressedSize) else {
                throw ZipReaderError.dataCorrupt("stored entry size mismatch")
            }
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipReaderError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize <= Self.maxEntryUncompressedSize else {
            throw ZipReaderError.fileTooLarge
        }
        if expectedSize == 0 { return Data() }
        guard !compressed.isEmpty,
              Double(expectedSize) / Double(max(compressed.count, 1)) <= Self.maxCompressionRatio else {
            throw ZipReaderError.fileTooLarge
        }

        var result = Data(count: expectedSize)
        let written = try result.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) -> Int in
            return try compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let srcBase = src.baseAddress, let destBase = dest.baseAddress else {
                    throw ZipReaderError.dataCorrupt("buffer address nil")
                }
                let headerOffset: Int = (src.count >= 2 && src[0] == 0x78) ? 2 : 0
                let srcPtr = srcBase.advanced(by: headerOffset)
                let outSize = compression_decode_buffer(destBase, dest.count, srcPtr, src.count - headerOffset, nil, COMPRESSION_ZLIB)
                guard outSize > 0 else { throw ZipReaderError.dataCorrupt("decompression failed") }
                guard outSize <= expectedSize else { throw ZipReaderError.fileTooLarge }
                return outSize
            }
        }
        result.count = written
        return result
    }

    private static func validateEntrySize(compressedSize: UInt32, uncompressedSize: UInt32) throws {
        guard Int(uncompressedSize) <= Self.maxEntryUncompressedSize else {
            throw ZipReaderError.fileTooLarge
        }
        guard Double(uncompressedSize) / Double(max(Int(compressedSize), 1)) <= Self.maxCompressionRatio else {
            throw ZipReaderError.fileTooLarge
        }
    }
}
