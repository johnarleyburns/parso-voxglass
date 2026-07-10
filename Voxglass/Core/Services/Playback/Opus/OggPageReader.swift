import Foundation

enum OggPageReaderError: Error, Equatable {
    case truncatedHeader
    case invalidCapturePattern
    case chainedStreamDetected
    case invalidPage
    case noOpusHead
    case opusHeadParseFailed
}

struct OggPageHeader {
    let granulePosition: Int64
    let streamSerial: UInt32
    let pageSequence: UInt32
    let isContinuation: Bool
    let isBeginningOfStream: Bool
    let isEndOfStream: Bool
    let segmentCount: UInt8
    let segmentTable: [UInt8]
    let headerSize: Int

    var totalSegmentSize: Int {
        segmentTable.map(Int.init).reduce(0, +)
    }
}

struct OpusHead {
    let version: UInt8
    let channelCount: UInt8
    let preSkip: UInt16
    let inputSampleRate: UInt32
    let outputGain: Int16
    let channelMappingFamily: UInt8

    static let magic: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]
}

struct OpusTags {
    let vendor: String
    let comments: [String]

    static let magic: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x54, 0x61, 0x67, 0x73]
}

final class OggPageReader {
    private let data: Data
    private var cursor: Int = 0
    private var seenBOS = false
    private var streamSerial: UInt32?
    private var partialPacket: Data?

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { cursor >= data.count }

    func nextPageHeader() throws -> OggPageHeader? {
        guard cursor + 27 <= data.count else {
            if cursor >= data.count { return nil }
            throw OggPageReaderError.truncatedHeader
        }

        let capture = data.subdata(in: cursor..<(cursor + 4))
        guard capture == Data([0x4F, 0x67, 0x67, 0x53]) else {
            throw OggPageReaderError.invalidCapturePattern
        }

        let version = data[cursor + 4]
        guard version == 0 else { throw OggPageReaderError.invalidPage }

        let headerType = data[cursor + 5]
        let isContinuation = (headerType & 0x01) != 0
        let isBeginningOfStream = (headerType & 0x02) != 0
        let isEndOfStream = (headerType & 0x04) != 0

        let granulePosition = readInt64LE(at: cursor + 6)
        let streamSerial = readUInt32LE(at: cursor + 14)
        let pageSequence = readUInt32LE(at: cursor + 18)
        let segmentCount = data[cursor + 26]
        let headerSize = 27 + Int(segmentCount)

        guard cursor + headerSize <= data.count else {
            throw OggPageReaderError.truncatedHeader
        }

        let segmentTable = Array(data.subdata(in: (cursor + 27)..<(cursor + headerSize)))

        if isBeginningOfStream {
            if seenBOS {
                throw OggPageReaderError.chainedStreamDetected
            }
            seenBOS = true
            self.streamSerial = streamSerial
        }

        if let expectedSerial = self.streamSerial, streamSerial != expectedSerial {
            throw OggPageReaderError.chainedStreamDetected
        }

        return OggPageHeader(
            granulePosition: granulePosition,
            streamSerial: streamSerial,
            pageSequence: pageSequence,
            isContinuation: isContinuation,
            isBeginningOfStream: isBeginningOfStream,
            isEndOfStream: isEndOfStream,
            segmentCount: segmentCount,
            segmentTable: segmentTable,
            headerSize: headerSize
        )
    }

    func advancePastHeader(_ header: OggPageHeader) {
        cursor += header.headerSize
    }

    func readPagePayload(_ header: OggPageHeader) -> Data {
        let size = header.totalSegmentSize
        guard cursor + size <= data.count else { return Data() }
        let payload = data.subdata(in: cursor..<(cursor + size))
        cursor += size
        return payload
    }

    func readPacketsInPage(_ header: OggPageHeader, payload: Data) -> [Data] {
        var packets: [Data] = []
        var offset = 0
        var isContinuingPacket = header.isContinuation

        // If continuing from previous page, start with the partial packet
        if isContinuingPacket, let existing = partialPacket {
            packets.append(existing)
            partialPacket = nil
        }

        for segmentSize in header.segmentTable {
            let size = Int(segmentSize)
            guard offset + size <= payload.count else { break }
            let segment = payload.subdata(in: offset..<(offset + size))
            offset += size

            if isContinuingPacket {
                // Append to the last (incomplete) packet
                if var last = packets.popLast() {
                    last.append(segment)
                    packets.append(last)
                } else {
                    packets.append(segment)
                }
            } else {
                packets.append(segment)
            }

            isContinuingPacket = (segmentSize == 255)
        }

        // If the last packet is incomplete (last segment was 255), save it for next page
        if isContinuingPacket, let incomplete = packets.popLast() {
            partialPacket = incomplete
        }

        return packets
    }

    static func parseOpusHead(from packet: Data) throws -> OpusHead {
        guard packet.count >= 19 else { throw OggPageReaderError.opusHeadParseFailed }
        let magic = packet.prefix(8)
        guard magic == Data(OpusHead.magic) else { throw OggPageReaderError.opusHeadParseFailed }

        return OpusHead(
            version: packet[8],
            channelCount: packet[9],
            preSkip: readUInt16LE(packet, at: 10),
            inputSampleRate: readUInt32LE(packet, at: 12),
            outputGain: Int16(bitPattern: readUInt16LE(packet, at: 16)),
            channelMappingFamily: packet[18]
        )
    }

    static func isOpusTagsMagic(_ packet: Data) -> Bool {
        packet.count >= 8 && packet.prefix(8) == Data(OpusTags.magic)
    }

    static func parseOpusTags(from packet: Data) -> OpusTags? {
        guard packet.count >= 12 else { return nil }
        let magic = packet.prefix(8)
        guard magic == Data(OpusTags.magic) else { return nil }

        let vendorLength = Int(readUInt32LE(packet, at: 8))
        let vendorOffset = 12
        guard vendorOffset + vendorLength <= packet.count else { return nil }

        let vendorData = packet.subdata(in: vendorOffset..<(vendorOffset + vendorLength))
        let vendor = String(data: vendorData, encoding: .utf8) ?? ""

        var cursor = vendorOffset + vendorLength
        guard cursor + 4 <= packet.count else {
            return OpusTags(vendor: vendor, comments: [])
        }

        let commentCount = Int(readUInt32LE(packet, at: cursor))
        cursor += 4
        var comments: [String] = []

        for _ in 0..<commentCount {
            guard cursor + 4 <= packet.count else { break }
            let length = Int(readUInt32LE(packet, at: cursor))
            cursor += 4
            guard cursor + length <= packet.count else { break }
            let commentData = packet.subdata(in: cursor..<(cursor + length))
            if let comment = String(data: commentData, encoding: .utf8) {
                comments.append(comment)
            }
            cursor += length
        }

        return OpusTags(vendor: vendor, comments: comments)
    }

    private func readInt64LE(at offset: Int) -> Int64 {
        var value: Int64 = 0
        for i in 0..<8 {
            value |= Int64(data[offset + i]) << (i * 8)
        }
        return value
    }

    private func readUInt32LE(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[offset + i]) << (i * 8)
        }
        return value
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[offset + i]) << (i * 8)
        }
        return value
    }
}
