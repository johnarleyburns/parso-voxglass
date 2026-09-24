import Foundation
import Testing
@testable import VoxglassCore

@Suite struct ZipReaderSecurityTests {
    @Test func rejectsAnEntryLargerThanTheDecompressionLimit() {
        let archive = makeStoredArchive(uncompressedSize: UInt32(ZipReader.maxEntryUncompressedSize + 1))

        do {
            _ = try ZipReader(data: archive)
            #expect(Bool(false), "ZIP entry exceeded the configured decompression limit")
        } catch ZipReaderError.fileTooLarge {
            // Expected: archive metadata is rejected before any extraction.
        } catch {
            #expect(Bool(false), "Unexpected ZIP error: \(error)")
        }
    }

    @Test func rejectsAnExtremeCompressionRatio() {
        let archive = makeStoredArchive(uncompressedSize: 2_001)

        do {
            _ = try ZipReader(data: archive)
            #expect(Bool(false), "ZIP entry exceeded the configured compression-ratio limit")
        } catch ZipReaderError.fileTooLarge {
            // Expected: expansion ratio is rejected from central-directory metadata.
        } catch {
            #expect(Bool(false), "Unexpected ZIP error: \(error)")
        }
    }

    private func makeStoredArchive(uncompressedSize: UInt32) -> Data {
        var data = Data()
        appendUInt32(0x04034b50, to: &data)
        appendUInt16(20, to: &data) // version needed
        appendUInt16(0, to: &data) // flags
        appendUInt16(0, to: &data) // stored
        appendUInt16(0, to: &data) // time
        appendUInt16(0, to: &data) // date
        appendUInt32(0, to: &data) // CRC
        appendUInt32(1, to: &data) // compressed size
        appendUInt32(uncompressedSize, to: &data)
        appendUInt16(1, to: &data) // filename length
        appendUInt16(0, to: &data) // extra length
        data.append(0x78) // filename
        data.append(0) // one byte of stored data

        let directoryOffset = UInt32(data.count)
        appendUInt32(0x02014b50, to: &data)
        appendUInt16(20, to: &data) // version made by
        appendUInt16(20, to: &data) // version needed
        appendUInt16(0, to: &data) // flags
        appendUInt16(0, to: &data) // stored
        appendUInt16(0, to: &data) // time
        appendUInt16(0, to: &data) // date
        appendUInt32(0, to: &data) // CRC
        appendUInt32(1, to: &data) // compressed size
        appendUInt32(uncompressedSize, to: &data)
        appendUInt16(1, to: &data) // filename length
        appendUInt16(0, to: &data) // extra length
        appendUInt16(0, to: &data) // comment length
        appendUInt16(0, to: &data) // disk number
        appendUInt16(0, to: &data) // internal attributes
        appendUInt32(0, to: &data) // external attributes
        appendUInt32(0, to: &data) // local-header offset
        data.append(0x78)

        let directorySize = UInt32(data.count) - directoryOffset
        appendUInt32(0x06054b50, to: &data)
        appendUInt16(0, to: &data) // disk number
        appendUInt16(0, to: &data) // directory disk
        appendUInt16(1, to: &data) // entries on disk
        appendUInt16(1, to: &data) // total entries
        appendUInt32(directorySize, to: &data)
        appendUInt32(directoryOffset, to: &data)
        appendUInt16(0, to: &data) // comment length
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }
}
