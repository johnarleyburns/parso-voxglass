import Foundation

/// MPEG-1 Layer III frame-header inspection (§16.3 verification tests,
/// §19.3 `TranscoderCBRTests`). Voxglass's MP3s must be *true* CBR — every
/// frame carrying the same bitrate index — because LibriVox rejects VBR and
/// ACX requires ≥ 192 kbps CBR. This parser proves conformance by walking the
/// frame stream, exactly the way an MP3Checker would.
public enum MP3FrameParser {

    /// Bitrate table (kbps) for MPEG-1 Layer III, indexed by the 4-bit bitrate
    /// index from the frame header. Index 0 = free format, 15 = bad.
    public static let mpeg1Layer3BitratesKbps: [Int] = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]

    /// Sample-rate table (Hz) for MPEG-1, indexed by the 2-bit index.
    public static let mpeg1SampleRatesHz: [Double] = [44_100, 48_000, 32_000]

    public struct FrameHeader: Sendable, Equatable {
        public var offset: Int
        public var bitrateKbps: Int
        public var sampleRateHz: Double
        public var padding: Bool
        public var channelMode: Int
        /// Mono = channel mode index 3 (`11`), the mode every Voxglass MP3 uses.
        public var isMono: Bool { channelMode == 3 }
        /// Frame length in bytes (including the 4-byte header), Layer III:
        /// `144 * bitrate / samplerate + padding`.
        public var frameLength: Int
    }

    public struct Summary: Sendable, Equatable {
        public var frames: [FrameHeader]
        public var averageBitrateKbps: Double
        public var distinctBitrateIndexes: Set<Int>
        public var isCBR: Bool { distinctBitrateIndexes.count == 1 }
    }

    /// Parse every frame in `data`, skipping any ID3 tag at the head.
    public static func parse(_ data: Data) -> Summary {
        var bytes = [UInt8](data)
        var offset = 0
        if let tagSize = id3TagSize(bytes) {
            offset = tagSize
        }
        var frames: [FrameHeader] = []
        var indexes = Set<Int>()
        let count = bytes.count

        while offset + 4 <= count {
            // Find the next sync word 0xFFEx.
            if bytes[offset] != 0xFF || (bytes[offset + 1] & 0xE0) != 0xE0 {
                offset += 1
                continue
            }
            let b1 = bytes[offset + 1]
            let b2 = bytes[offset + 2]
            let b3 = bytes[offset + 3]

            // MPEG version ID: 1 (bits 4-3 = 01) is MPEG-1. Layer: 01 = Layer III.
            let versionID = (b1 >> 3) & 0x03
            let layerID = (b1 >> 1) & 0x03
            guard versionID == 3, layerID == 1 else {
                offset += 1
                continue
            }

            let bitrateIndex = Int((b2 >> 4) & 0x0F)
            let sampleRateIndex = Int((b2 >> 2) & 0x03)
            guard bitrateIndex > 0, bitrateIndex < 15, sampleRateIndex < 3 else {
                offset += 1
                continue
            }

            let bitrate = mpeg1Layer3BitratesKbps[bitrateIndex]
            let sampleRate = mpeg1SampleRatesHz[sampleRateIndex]
            let padding = (b2 & 0x01) != 0
            let channelMode = Int((b3 >> 6) & 0x03)

            let frameLength = 144 * bitrate * 1000 / Int(sampleRate) + (padding ? 1 : 0)
            guard offset + frameLength <= count else {
                // The final frame may be truncated by the flush; stop scanning.
                frames.append(FrameHeader(offset: offset, bitrateKbps: bitrate, sampleRateHz: sampleRate, padding: padding, channelMode: channelMode, frameLength: frameLength))
                break
            }
            frames.append(FrameHeader(offset: offset, bitrateKbps: bitrate, sampleRateHz: sampleRate, padding: padding, channelMode: channelMode, frameLength: frameLength))
            indexes.insert(bitrateIndex)
            offset += frameLength
        }

        let average = frames.isEmpty ? 0 : Double(frames.map(\.bitrateKbps).reduce(0, +)) / Double(frames.count)
        return Summary(frames: frames, averageBitrateKbps: average, distinctBitrateIndexes: indexes)
    }

    /// `true` if `data` decodes as mono, 44.1 kHz, `expectedKbps` CBR — the
    /// LibriVox contract (§3.2.1) and the ACX minimum (§3.4.1).
    public static func verifies(
        data: Data,
        expectedKbps: Int,
        sampleRateHz: Double = 44_100,
        mono: Bool = true
    ) -> Bool {
        let summary = parse(data)
        guard !summary.frames.isEmpty else { return false }
        return summary.isCBR
            && summary.frames.allSatisfy { $0.bitrateKbps == expectedKbps }
            && summary.frames.allSatisfy { $0.sampleRateHz == sampleRateHz }
            && (!mono || summary.frames.allSatisfy(\.isMono))
    }

    /// Length in bytes of an ID3v2 tag at the head of `bytes`, or nil if none.
    private static func id3TagSize(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return nil }
        let version = bytes[3]
        guard version >= 2, version <= 4 else { return nil }
        let size = (Int(bytes[6]) << 21) | (Int(bytes[7]) << 14) | (Int(bytes[8]) << 7) | Int(bytes[9])
        return size + 10
    }
}
