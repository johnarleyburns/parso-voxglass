import XCTest
@testable import Voxglass

final class OggPageReaderTests: XCTestCase {

    // MARK: - Page parsing

    func testSinglePageWithOnePacket() throws {
        let ogg = OggTestData.singlePage(serial: 1, pageSeq: 0, granule: 0,
                                           packets: [Data([0x01, 0x02, 0x03])])
        let reader = OggPageReader(data: ogg)

        let header = try XCTUnwrap(reader.nextPageHeader())
        XCTAssertTrue(header.isBeginningOfStream)
        XCTAssertFalse(header.isContinuation)
        XCTAssertEqual(header.granulePosition, 0)
        XCTAssertEqual(header.streamSerial, 1)
        XCTAssertEqual(header.pageSequence, 0)

        reader.advancePastHeader(header)
        let payload = reader.readPagePayload(header)
        let packets = reader.readPacketsInPage(header, payload: payload)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0], Data([0x01, 0x02, 0x03]))
    }

    func testMultiPacketPage() throws {
        let packet1 = Data(repeating: 0x41, count: 200)
        let packet2 = Data(repeating: 0x42, count: 100)
        let ogg = OggTestData.singlePage(serial: 1, pageSeq: 0, granule: 0,
                                           packets: [packet1, packet2])
        let reader = OggPageReader(data: ogg)

        let header = try XCTUnwrap(reader.nextPageHeader())
        reader.advancePastHeader(header)
        let payload = reader.readPagePayload(header)
        let packets = reader.readPacketsInPage(header, payload: payload)

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].count, 200)
        XCTAssertEqual(packets[1].count, 100)
    }

    func testPacketSpanningTwoPages() throws {
        let fullPacket = Data(repeating: 0xAA, count: 500)
        let ogg = OggTestData.twoPagePacket(serial: 2, packet: fullPacket)
        let reader = OggPageReader(data: ogg)

        // Page 1 (continuation, BOS)
        let header1 = try XCTUnwrap(reader.nextPageHeader())
        XCTAssertTrue(header1.isBeginningOfStream)
        reader.advancePastHeader(header1)
        let payload1 = reader.readPagePayload(header1)
        let packets1 = reader.readPacketsInPage(header1, payload: payload1)
        XCTAssertEqual(packets1.count, 1)
        XCTAssertTrue(packets1[0].count < 500)

        // Page 2 (continuation, end)
        let header2 = try XCTUnwrap(reader.nextPageHeader())
        XCTAssertTrue(header2.isContinuation)
        XCTAssertTrue(header2.isEndOfStream)
        reader.advancePastHeader(header2)
        let payload2 = reader.readPagePayload(header2)
        let packets2 = reader.readPacketsInPage(header2, payload: payload2)
        XCTAssertEqual(packets2.count, 1)

        // Combined should be the full packet
        let combined = packets1[0] + packets2[0]
        XCTAssertEqual(combined, fullPacket)
    }

    func testNonzeroGranulePosition() throws {
        let ogg = OggTestData.singlePage(serial: 1, pageSeq: 5, granule: 96000,
                                           packets: [Data([0x01])])
        let reader = OggPageReader(data: ogg)
        let header = try XCTUnwrap(reader.nextPageHeader())
        XCTAssertEqual(header.granulePosition, 96000)
        XCTAssertEqual(header.pageSequence, 5)
    }

    // MARK: - Chained stream rejection

    func testChainedStreamRejected() throws {
        // Two BOS pages with different serials = chained stream
        let ogg = OggTestData.chainedStream()
        let reader = OggPageReader(data: ogg)

        _ = try reader.nextPageHeader() // first BOS ok

        XCTAssertThrowsError(try reader.nextPageHeader()) { error in
            XCTAssertEqual(error as? OggPageReaderError, .chainedStreamDetected)
        }
    }

    // MARK: - OpusHead parsing

    func testParseOpusHead() throws {
        let opusHead = OggTestData.opusHeadPacket(channels: 2, preSkip: 312, sampleRate: 48000)
        let parsed = try OggPageReader.parseOpusHead(from: opusHead)

        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.channelCount, 2)
        XCTAssertEqual(parsed.preSkip, 312)
        XCTAssertEqual(parsed.inputSampleRate, 48000)
    }

    func testParseOpusHeadWithNonzeroPreSkip() throws {
        let opusHead = OggTestData.opusHeadPacket(channels: 1, preSkip: 3840, sampleRate: 48000)
        let parsed = try OggPageReader.parseOpusHead(from: opusHead)

        XCTAssertEqual(parsed.channelCount, 1)
        XCTAssertEqual(parsed.preSkip, 3840)
    }

    func testOpusHeadRejectsInvalidMagic() throws {
        let invalidData = Data(repeating: 0x00, count: 19)
        XCTAssertThrowsError(try OggPageReader.parseOpusHead(from: invalidData))
    }

    // MARK: - OpusTags parsing

    func testParseOpusTags() throws {
        let tags = OggTestData.opusTagsPacket(vendor: "libopus 1.3.1", comments: ["ENCODER=opusenc"])
        let parsed = OggPageReader.parseOpusTags(from: tags)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.vendor, "libopus 1.3.1")
        XCTAssertEqual(parsed?.comments, ["ENCODER=opusenc"])
    }
}

// MARK: - Ogg test data builder

private enum OggTestData {
    static let capturePattern: [UInt8] = [0x4F, 0x67, 0x67, 0x53] // "OggS"

    static func oggPage(
        serial: UInt32,
        pageSeq: UInt32,
        granule: Int64,
        flags: UInt8,
        packets: [Data]
    ) -> Data {
        var segments: [UInt8] = []
        for (i, packet) in packets.enumerated() {
            let isLastPacket = i == packets.count - 1
            var remaining = packet.count
            while remaining > 0 {
                if remaining >= 255 {
                    segments.append(255)
                    remaining -= 255
                } else {
                    segments.append(UInt8(remaining))
                    remaining = 0
                }
            }
            if isLastPacket && segments.last == 255 {
                segments.append(0)
            } else if !isLastPacket && segments.last != 255 {
                segments[segments.count - 1] = 255
                if packet.count % 255 == 0 {
                    segments.append(0)
                }
            }
        }

        var data = Data()
        data.append(contentsOf: capturePattern)          // 0-3: "OggS"
        data.append(0)                                    // 4: version
        data.append(flags)                                // 5: header type flags
        data.append(contentsOf: writeInt64LE(granule))   // 6-13: granule position
        data.append(contentsOf: writeUInt32LE(serial))   // 14-17: serial
        data.append(contentsOf: writeUInt32LE(pageSeq))  // 18-21: page sequence
        data.append(contentsOf: [0, 0, 0, 0])            // 22-25: checksum (zero)
        data.append(UInt8(segments.count))               // 26: segment count
        data.append(contentsOf: segments)                // 27+: segment table

        for packet in packets {
            data.append(contentsOf: packet)
        }

        return data
    }

    static func singlePage(serial: UInt32, pageSeq: UInt32, granule: Int64, packets: [Data]) -> Data {
        oggPage(serial: serial, pageSeq: pageSeq, granule: granule, flags: 0x02, packets: packets)
    }

    static func twoPagePacket(serial: UInt32, packet: Data) -> Data {
        let splitAt = min(255, packet.count / 2)
        let part1 = packet.prefix(splitAt)
        let part2 = packet.suffix(from: splitAt)

        let page1 = oggPage(serial: serial, pageSeq: 0, granule: -1,
                            flags: 0x02, packets: [Data(part1)])
        let page2 = oggPage(serial: serial, pageSeq: 1, granule: 960,
                            flags: 0x01 | 0x04, packets: [Data(part2)])
        return page1 + page2
    }

    static func chainedStream() -> Data {
        let page1 = oggPage(serial: 1, pageSeq: 0, granule: 0, flags: 0x02, packets: [Data([0x01])])
        let page2 = oggPage(serial: 2, pageSeq: 0, granule: 960, flags: 0x02, packets: [Data([0x02])])
        return page1 + page2
    }

    static func opusHeadPacket(channels: UInt8, preSkip: UInt16, sampleRate: UInt32) -> Data {
        var data = Data()
        data.append(contentsOf: OpusHead.magic)       // 0-7: "OpusHead"
        data.append(1)                                 // 8: version
        data.append(channels)                          // 9: channels
        data.append(contentsOf: writeUInt16LE(preSkip)) // 10-11: pre-skip
        data.append(contentsOf: writeUInt32LE(sampleRate))// 12-15: input sample rate
        data.append(contentsOf: [0, 0])                // 16-17: output gain
        data.append(0)                                 // 18: channel mapping family
        return data
    }

    static func opusTagsPacket(vendor: String, comments: [String]) -> Data {
        var data = Data()
        data.append(contentsOf: OpusTags.magic)        // 0-7: "OpusTags"

        let vendorBytes = Array(vendor.utf8)
        data.append(contentsOf: writeUInt32LE(UInt32(vendorBytes.count)))
        data.append(contentsOf: vendorBytes)

        data.append(contentsOf: writeUInt32LE(UInt32(comments.count)))
        for comment in comments {
            let commentBytes = Array(comment.utf8)
            data.append(contentsOf: writeUInt32LE(UInt32(commentBytes.count)))
            data.append(contentsOf: commentBytes)
        }

        return data
    }

    private static func writeInt64LE(_ value: Int64) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    private static func writeUInt32LE(_ value: UInt32) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }

    private static func writeUInt16LE(_ value: UInt16) -> [UInt8] {
        var v = value
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}
