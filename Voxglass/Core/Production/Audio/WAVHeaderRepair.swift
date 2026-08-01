import Foundation

/// Repairs a WAV whose RIFF/data chunk sizes were never finalized (spec §7.7).
///
/// A WAV written by `AVAudioFile` that was never closed has a stale header: the
/// `data` chunk's size field (and the RIFF size) hold the capacity that was
/// allocated, not the bytes actually written. Before any crash-recovery decode,
/// `repairInPlace` rewrites both sizes from the actual file length.
public enum WAVHeaderRepair {
    public enum RepairError: Error, Equatable {
        case notAWAV
        case truncatedHeader
        case noDataChunk
    }

    /// Rewrites the RIFF and `data` chunk sizes to match the file length.
    /// Returns `true` if a repair was applied, `false` if the header was
    /// already consistent (data size equals the bytes after the header).
    public static func repairInPlace(url: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw RepairError.notAWAV }
        let fileSize = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard fileSize >= 12 else { throw RepairError.notAWAV }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        guard let riff = try read(handle, offset: 0, count: 4), riff == "RIFF" else {
            throw RepairError.notAWAV
        }
        guard let wave = try read(handle, offset: 8, count: 4), wave == "WAVE" else {
            throw RepairError.notAWAV
        }
        guard fileSize >= 44 else { throw RepairError.truncatedHeader }

        // Locate the "data" chunk. fmt is usually first; scan chunks in case
        // of extra chunks (e.g. "LIST", "fact", "bext").
        var offset: UInt64 = 12
        var dataSizeFieldOffset: UInt64 = 0
        var dataBodyOffset: UInt64 = 0
        var dataChunkSize: UInt32 = 0
        while offset + 8 <= fileSize {
            guard let chunkID = try read(handle, offset: offset, count: 4) else {
                throw RepairError.truncatedHeader
            }
            let sizeBytes = try handle.read(upToCount: 4)
            guard let sizeBytes, sizeBytes.count == 4 else { throw RepairError.truncatedHeader }
            let chunkSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) } // native endian
            if chunkID == "data" {
                dataSizeFieldOffset = offset + 4
                dataBodyOffset = offset + 8
                dataChunkSize = chunkSize
                break
            }
            let chunkBody: UInt64 = UInt64(chunkSize) + UInt64(chunkSize) % 2
            offset += 8 + chunkBody
        }
        guard dataBodyOffset > 0 else { throw RepairError.noDataChunk }

        let actualDataSize = fileSize - dataBodyOffset

        if UInt64(dataChunkSize) == actualDataSize {
            return false
        }

        // The file was never closed (or was truncated): fix the chunk size,
        // then the RIFF size, then truncate any trailing junk (e.g. a stale
        // "fact" chunk) so the header and content agree.
        var newDataSize = UInt32(actualDataSize)
        try write(handle, offset: dataSizeFieldOffset, data: withUnsafeBytes(of: &newDataSize) { Data($0) })

        var newRiffSize = UInt32(actualDataSize + 36)
        try write(handle, offset: 4, data: withUnsafeBytes(of: &newRiffSize) { Data($0) })

        if dataBodyOffset + actualDataSize < fileSize {
            try handle.truncate(atOffset: dataBodyOffset + actualDataSize)
        }
        return true
    }

    private static func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> String? {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ handle: FileHandle, offset: UInt64, data: Data) throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
    }
}
