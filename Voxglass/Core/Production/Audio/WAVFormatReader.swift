import Foundation

/// Basic properties parsed from a RIFF/WAVE file header (spec §7.4 step 2:
/// a take is only recoverable "if the file is valid"). Recovery calls
/// `WAVHeaderRepair.repairInPlace` first, so the chunk sizes here are the
/// finalized ones; this type exists so Core can validate and describe a
/// recovered file without AVFoundation.
public struct WAVFormatInfo: Sendable, Equatable {
    public var sampleRate: Double
    public var channels: Int
    public var bitDepth: Int
    /// Bytes in the `data` chunk (the actual PCM payload).
    public var dataByteCount: Int
    /// True when the `fmt` chunk declares IEEE float PCM.
    public var isFloat: Bool

    /// Duration in seconds derived from the data size and format.
    public var duration: TimeInterval {
        let bytesPerSample = max((bitDepth + 7) / 8, 1)
        let frameBytes = Double(max(channels, 1) * bytesPerSample)
        guard frameBytes > 0 else { return 0 }
        return Double(dataByteCount) / frameBytes / max(sampleRate, 1)
    }

    /// The `AudioFormatDescription` equivalent for take metadata.
    public var audioFormat: AudioFormatDescription {
        AudioFormatDescription(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            codec: isFloat ? "pcm_float" : "pcm"
        )
    }

    public init(sampleRate: Double, channels: Int, bitDepth: Int, dataByteCount: Int, isFloat: Bool) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitDepth = bitDepth
        self.dataByteCount = dataByteCount
        self.isFloat = isFloat
    }
}

public enum WAVFormatReader {
    public enum ReadError: Error, Equatable {
        case notAWAV
        case truncatedHeader
        case noFmtChunk
        case noDataChunk
        case malformedFmtChunk
    }

    /// Parses the RIFF/WAVE header of `url`.
    public static func read(url: URL) throws -> WAVFormatInfo {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw ReadError.notAWAV }
        let fileSize = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard fileSize >= 12 else { throw ReadError.notAWAV }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let riff = try readString(handle, offset: 0, count: 4), riff == "RIFF" else {
            throw ReadError.notAWAV
        }
        guard let wave = try readString(handle, offset: 8, count: 4), wave == "WAVE" else {
            throw ReadError.notAWAV
        }

        var offset: UInt64 = 12
        var fmt: (channels: Int, sampleRate: Double, bitDepth: Int, isFloat: Bool)?
        var dataBodyOffset: UInt64?
        var dataSizeField: UInt32 = 0

        while offset + 8 <= fileSize {
            guard let chunkID = try readString(handle, offset: offset, count: 4) else {
                throw ReadError.truncatedHeader
            }
            let sizeBytes = try handle.read(upToCount: 4)
            guard let sizeBytes, sizeBytes.count == 4 else { throw ReadError.truncatedHeader }
            let chunkSize = sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) } // native endian (little on all supported platforms)
            let bodyOffset = offset + 8
            if chunkID == "fmt " {
                fmt = try parseFMT(handle, at: bodyOffset, declaredSize: chunkSize)
            } else if chunkID == "data" {
                dataBodyOffset = bodyOffset
                dataSizeField = chunkSize
                break
            }
            let chunkBody: UInt64 = UInt64(chunkSize) + UInt64(chunkSize) % 2
            offset += 8 + chunkBody
        }

        guard let fmt else { throw ReadError.noFmtChunk }
        guard let dataBodyOffset else { throw ReadError.noDataChunk }

        // Trust the repaired data size; clamp to the real file remainder so a
        // stale header can never report bytes that do not exist.
        let actual = fileSize - dataBodyOffset
        let dataByteCount = min(UInt64(dataSizeField), actual)

        return WAVFormatInfo(
            sampleRate: fmt.sampleRate,
            channels: fmt.channels,
            bitDepth: fmt.bitDepth,
            dataByteCount: Int(dataByteCount),
            isFloat: fmt.isFloat
        )
    }

    private static func parseFMT(_ handle: FileHandle, at offset: UInt64, declaredSize: UInt32) throws -> (channels: Int, sampleRate: Double, bitDepth: Int, isFloat: Bool) {
        guard declaredSize >= 16 else { throw ReadError.malformedFmtChunk }
        try handle.seek(toOffset: offset)
        guard let bytes = try handle.read(upToCount: 16), bytes.count == 16 else {
            throw ReadError.truncatedHeader
        }
        let u16 = { (i: Int) -> Int in Int(bytes[bytes.startIndex + i]) | (Int(bytes[bytes.startIndex + i + 1]) << 8) }
        let u32 = { (i: Int) -> UInt32 in
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(bytes[bytes.startIndex + i + k]) << (8 * k) }
            return v
        }
        let formatCode = u16(0)
        let channels = u16(2)
        let sampleRate = u32(4)
        let bitDepth = u16(14)
        guard channels > 0, sampleRate > 0 else { throw ReadError.malformedFmtChunk }
        let isFloat = formatCode == 3
        return (channels, Double(sampleRate), bitDepth, isFloat)
    }

    private static func readString(_ handle: FileHandle, offset: UInt64, count: Int) throws -> String? {
        try handle.seek(toOffset: offset)
        guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
