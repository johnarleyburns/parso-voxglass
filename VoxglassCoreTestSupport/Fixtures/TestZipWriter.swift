import Foundation
import VoxglassCore

/// Minimal ZIP writer for test fixtures. Writes stored (uncompressed, method
/// 0) entries, which `ZipReader` supports — no deflate dependency. Used to
/// build EPUB and DOCX fixtures (§19.3: one fixture per format).
public enum TestZipWriter {

    public static func write(entries: [(name: String, data: Data)], to url: URL) throws {
        var data = Data()
        var centralDirectory = Data()
        var offset = 0

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)

            // Local file header.
            var local = Data()
            appendUInt32(0x04034b50, to: &local)
            appendUInt16(20, to: &local)                 // version needed
            appendUInt16(0x0800, to: &local)              // flags (UTF-8 names)
            appendUInt16(0, to: &local)                   // method: stored
            appendUInt16(0, to: &local)                   // mod time
            appendUInt16(0, to: &local)                   // mod date
            appendUInt32(crc, to: &local)
            appendUInt32(size, to: &local)
            appendUInt32(size, to: &local)
            appendUInt16(UInt16(nameBytes.count), to: &local)
            appendUInt16(0, to: &local)                   // extra length
            local.append(nameBytes)

            data.append(local)
            data.append(entry.data)

            // Central directory record.
            var central = Data()
            appendUInt32(0x02014b50, to: &central)
            appendUInt16(20, to: &central)                // version made by
            appendUInt16(20, to: &central)                // version needed
            appendUInt16(0x0800, to: &central)            // flags
            appendUInt16(0, to: &central)                 // method: stored
            appendUInt16(0, to: &central)                 // mod time
            appendUInt16(0, to: &central)                 // mod date
            appendUInt32(crc, to: &central)
            appendUInt32(size, to: &central)
            appendUInt32(size, to: &central)
            appendUInt16(UInt16(nameBytes.count), to: &central)
            appendUInt16(0, to: &central)                 // extra length
            appendUInt16(0, to: &central)                 // comment length
            appendUInt16(0, to: &central)                 // disk number
            appendUInt16(0, to: &central)                 // internal attrs
            appendUInt32(0, to: &central)                 // external attrs
            appendUInt32(UInt32(offset), to: &central)    // local header offset
            central.append(nameBytes)

            centralDirectory.append(central)
            offset += local.count + entry.data.count
        }

        // End of central directory record.
        var end = Data()
        appendUInt32(0x06054b50, to: &end)
        appendUInt16(0, to: &end)
        appendUInt16(0, to: &end)
        appendUInt16(UInt16(entries.count), to: &end)
        appendUInt16(UInt16(entries.count), to: &end)
        appendUInt32(UInt32(centralDirectory.count), to: &end)
        appendUInt32(UInt32(data.count), to: &end)
        appendUInt16(0, to: &end)

        data.append(centralDirectory)
        data.append(end)
        try data.write(to: url)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
