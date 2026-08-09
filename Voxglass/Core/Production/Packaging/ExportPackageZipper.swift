import Foundation

/// A minimal, dependency-free ZIP writer that stores entries without
/// compression (method 0). Delivered audio is already MP3/FLAC/WAV, so a
/// stored zip adds no meaningful size penalty, and "Save to Files" round-trips
/// a single `.zip` most reliably on iPhone (§4.4, §13.4). Pure Foundation — no
/// third-party archive framework — so it works on Linux test runners too.
public enum ExportPackageZipper {

    /// Zips every file under `directory` (flat, non-recursive) into `outputURL`
    /// and returns it. Entry names are relative to `directory`.
    public static func zipContents(of directory: URL, to outputURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        let files = entries.compactMap { url -> URL? in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false else { return nil }
            return url
        }
        return try zip(files: files, under: directory, to: outputURL)
    }

    /// Writes a stored zip of `files` whose entry names are relative to `root`.
    public static func zip(files: [URL], under root: URL, to outputURL: URL) throws -> URL {
        try? FileManager.default.removeItem(at: outputURL)
        let output = try FileHandle(forWritingTo: Self.materialize(outputURL))
        defer { try? output.close() }

        var centralDirectory = Data()
        var offset: UInt64 = 0
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }

        for file in sorted {
            let name = Self.relativePath(of: file, under: root)
            let nameBytes = Array(name.utf8)
            let data = try Data(contentsOf: file)
            let crc = Self.crc32(data)
            let sizes = UInt32(data.count)

            let dos = Self.dosDateTime()

            // Local file header (signature 0x04034b50).
            var local = Data()
            Self.append(UInt32(0x04034b50), to: &local)
            Self.append(UInt16(20), to: &local)        // version needed
            Self.append(UInt16(0), to: &local)         // general purpose flags
            Self.append(UInt16(0), to: &local)         // compression: stored
            Self.append(dos.time, to: &local)
            Self.append(dos.date, to: &local)
            Self.append(crc, to: &local)
            Self.append(sizes, to: &local)             // compressed size
            Self.append(sizes, to: &local)             // uncompressed size
            Self.append(UInt16(nameBytes.count), to: &local)
            Self.append(UInt16(0), to: &local)         // extra field length
            local.append(contentsOf: nameBytes)
            try output.write(contentsOf: local)
            try output.write(contentsOf: data)

            // Central directory header (signature 0x02014b50).
            var central = Data()
            Self.append(UInt32(0x02014b50), to: &central)
            Self.append(UInt16(20), to: &central)      // version made by
            Self.append(UInt16(20), to: &central)      // version needed
            Self.append(UInt16(0), to: &central)       // flags
            Self.append(UInt16(0), to: &central)       // compression
            Self.append(dos.time, to: &central)
            Self.append(dos.date, to: &central)
            Self.append(crc, to: &central)
            Self.append(sizes, to: &central)
            Self.append(sizes, to: &central)
            Self.append(UInt16(nameBytes.count), to: &central)
            Self.append(UInt16(0), to: &central)       // extra
            Self.append(UInt16(0), to: &central)       // comment
            Self.append(UInt16(0), to: &central)       // disk
            Self.append(UInt16(0), to: &central)       // internal attrs
            Self.append(UInt32(0), to: &central)       // external attrs
            Self.append(UInt32(truncatingIfNeeded: offset), to: &central)
            central.append(contentsOf: nameBytes)
            centralDirectory.append(central)

            offset += UInt64(local.count) + UInt64(data.count)
        }

        let centralOffset = offset
        try output.write(contentsOf: centralDirectory)

        // End of central directory (signature 0x06054b50).
        var end = Data()
        Self.append(UInt32(0x06054b50), to: &end)
        Self.append(UInt16(0), to: &end)               // disk number
        Self.append(UInt16(0), to: &end)               // cd start disk
        Self.append(UInt16(files.count), to: &end)     // entries on disk
        Self.append(UInt16(files.count), to: &end)     // total entries
        Self.append(UInt32(centralDirectory.count), to: &end)
        Self.append(UInt32(truncatingIfNeeded: centralOffset), to: &end)
        Self.append(UInt16(0), to: &end)               // comment length
        try output.write(contentsOf: end)

        return outputURL
    }

    /// The on-disk URL (creating the parent directory) so `FileHandle(forWritingTo:)`
    /// never has to create intermediate directories.
    private static func materialize(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    private static func relativePath(of file: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return file.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// ZIP's MS-DOS date/time. All entries share the epoch so output is
    /// byte-deterministic for identical content.
    private static func dosDateTime() -> (time: UInt16, date: UInt16) {
        (0, 0x21) // 1980-01-01 00:00:00 — deterministic and stable
    }

    private static func append(_ value: UInt16, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}
