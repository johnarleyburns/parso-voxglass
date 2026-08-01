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
    private let data: Data
    private let entries: [ZipEntry]

    public init(data: Data) throws {
        self.data = data
        let endRecord = try Self.findEndOfCentralDirectory(in: data)
        self.entries = try Self.readCentralDirectory(in: data, endRecord: endRecord)
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public var fileNames: [String] { entries.map(\.filename) }

    public func entry(named name: String) -> ZipEntry? {
        entries.first { $0.filename == name }
    }

    public func read(_ entry: ZipEntry) throws -> Data {
        guard let idx = entries.firstIndex(where: { $0.filename == entry.filename }) else {
            throw ZipReaderError.dataCorrupt("entry not found in directory: \(entry.filename)")
        }
        _ = idx
        return try Self.extractFile(data: data, entry: entry)
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
        var entries: [ZipEntry] = []
        var offset = Int(endRecord.dirOffset)
        let limit = offset + Int(endRecord.dirSize)

        for _ in 0..<endRecord.entryCount {
            guard offset + 46 <= limit else { break }
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

            guard offset + 46 + filenameLen <= data.count else { break }
            let filename = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + filenameLen)), encoding: .utf8) ?? ""
            let isDirectory = filename.hasSuffix("/")

            entries.append(ZipEntry(
                filename: filename,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                crc32: crc32,
                compressionMethod: compressionMethod,
                localHeaderOffset: localHeaderOffset,
                isDirectory: isDirectory
            ))

            offset += 46 + filenameLen + extraLen + commentLen
        }

        return entries
    }

    private static func extractFile(data: Data, entry: ZipEntry) throws -> Data {
        var offset = Int(entry.localHeaderOffset)

        guard offset + 30 <= data.count else {
            throw ZipReaderError.dataCorrupt("local header out of bounds")
        }
        guard readUInt32(data, at: offset) == 0x04034b50 else {
            throw ZipReaderError.dataCorrupt("invalid local file header")
        }

        let filenameLen = Int(readUInt16(data, at: offset + 26))
        let extraLen = Int(readUInt16(data, at: offset + 28))
        offset += 30 + filenameLen + extraLen

        guard offset + Int(entry.compressedSize) <= data.count else {
            throw ZipReaderError.dataCorrupt("file data out of bounds")
        }

        let compressed = data.subdata(in: offset..<(offset + Int(entry.compressedSize)))

        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipReaderError.unsupportedCompression(entry.compressionMethod)
        }
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        var result = Data(count: expectedSize > 0 ? expectedSize : 1024 * 1024)
        let written = try result.withUnsafeMutableBytes { (dest: UnsafeMutableRawBufferPointer) -> Int in
            if dest.count == 0 {
                var big = Data(count: 1024 * 1024)
                return try big.withUnsafeMutableBytes { (bigDest: UnsafeMutableRawBufferPointer) -> Int in
                    try compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                        guard let srcBase = src.baseAddress, let destBase = bigDest.baseAddress else {
                            throw ZipReaderError.dataCorrupt("buffer address nil")
                        }
                        let outSize = compression_decode_buffer(destBase, bigDest.count, srcBase, src.count, nil, COMPRESSION_ZLIB)
                        guard outSize > 0 else { throw ZipReaderError.dataCorrupt("decompression failed") }
                        return outSize
                    }
                }
            }
            return try compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let srcBase = src.baseAddress, let destBase = dest.baseAddress else {
                    throw ZipReaderError.dataCorrupt("buffer address nil")
                }
                let headerOffset: Int = (src.count > 0 && src[0] == 0x78) ? 2 : 0
                let srcPtr = srcBase.advanced(by: headerOffset)
                let outSize = compression_decode_buffer(destBase, dest.count, srcPtr, src.count - headerOffset, nil, COMPRESSION_ZLIB)
                guard outSize > 0 else { throw ZipReaderError.dataCorrupt("decompression failed") }
                return outSize
            }
        }
        result.count = written
        return result
    }
}
