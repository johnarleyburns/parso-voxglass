import Foundation

enum CAFOpusWriterError: Error, Equatable {
    case writeFailed
}

final class CAFOpusWriter {
    private var packets: [(size: Int, validFrames: Int64)] = []
    private var totalFrameCount: Int64 = 0

    private static let kAudioFormatOpus: UInt32 = 0x6F707573
    private static let opusFrameLength: Int64 = 960

    let opusHead: OpusHead

    init(opusHead: OpusHead) {
        self.opusHead = opusHead
    }

    func writeOpusPacket(_ packet: Data, validFrames: Int64 = Self.opusFrameLength) {
        packets.append((size: packet.count, validFrames: validFrames))
        totalFrameCount += validFrames
    }

    var packetCount: Int { packets.count }

    func write(to fileURL: URL, lastGranulePosition: Int64, audioData: Data) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        guard fm.createFile(atPath: fileURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: fileURL) else {
            throw CAFOpusWriterError.writeFailed
        }
        defer { try? handle.close() }

        let primingFrames = Int32(opusHead.preSkip)
        let remainderFrames = Int32(lastGranulePosition) - Int32(totalFrameCount) - primingFrames

        // Build pakt payload first
        var paktPayload = Data()
        paktPayload.reserveCapacity(32 + packets.count * 20)

        // mNumberPackets
        paktPayload.append(Self.writeInt64BE(Int64(packets.count)))
        // mNumberValidFrames
        paktPayload.append(Self.writeInt64BE(totalFrameCount))
        // mPrimingFrames
        paktPayload.append(Self.writeInt32BE(primingFrames))
        // mRemainderFrames
        paktPayload.append(Self.writeInt32BE(remainderFrames > 0 ? remainderFrames : 0))

        for pkt in packets {
            paktPayload.append(Self.writeVarLenInt(pkt.validFrames))
            paktPayload.append(Self.writeVarLenInt(Int64(pkt.size)))
        }

        // CAF File Header
        try handle.write(contentsOf: Self.writeUInt32BE(0x63616666)) // 'caff'
        try handle.write(contentsOf: Self.writeUInt16BE(1))         // mFileVersion
        try handle.write(contentsOf: Self.writeUInt16BE(0))         // mFileFlags

        // Audio Description chunk ('desc')
        try handle.write(contentsOf: Self.writeChunkHeader("desc", size: 32))
        try handle.write(contentsOf: Self.writeFloat64BE(48000.0))  // mSampleRate
        try handle.write(contentsOf: Self.writeUInt32BE(Self.kAudioFormatOpus)) // mFormatID
        try handle.write(contentsOf: Self.writeUInt32BE(0))         // mFormatFlags
        try handle.write(contentsOf: Self.writeUInt32BE(0))         // mBytesPerPacket (VBR)
        try handle.write(contentsOf: Self.writeUInt32BE(0))         // mFramesPerPacket (variable)
        try handle.write(contentsOf: Self.writeUInt32BE(UInt32(opusHead.channelCount))) // mChannelsPerFrame
        try handle.write(contentsOf: Self.writeUInt32BE(0))         // mBitsPerChannel (compressed)

        // Packet Table chunk ('pakt')
        try handle.write(contentsOf: Self.writeChunkHeader("pakt", size: Int64(paktPayload.count)))
        try handle.write(contentsOf: paktPayload)

        // Audio Data chunk ('data')
        try handle.write(contentsOf: Self.writeChunkHeader("data", size: Int64(audioData.count)))
        try handle.write(contentsOf: audioData)
    }

    // MARK: - Binary helpers

    private static func writeChunkHeader(_ type: String, size: Int64) -> Data {
        var data = Data(type.utf8)
        data.append(writeInt64BE(size))
        return data
    }

    private static func writeUInt32BE(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func writeUInt16BE(_ value: UInt16) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 2)
    }

    private static func writeFloat64BE(_ value: Float64) -> Data {
        var be = value.bitPattern.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private static func writeInt64BE(_ value: Int64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private static func writeInt32BE(_ value: Int32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func writeVarLenInt(_ value: Int64) -> Data {
        var result = Data()
        var v = value
        if v == 0 {
            result.append(0)
            return result
        }
        while v != 0 {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 {
                byte |= 0x80
            }
            result.append(byte)
        }
        return result
    }
}
