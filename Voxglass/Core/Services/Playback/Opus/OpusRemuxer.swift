import Foundation

enum OpusRemuxerError: Error, Equatable {
    case fileReadFailed
    case noOpusStream
    case corruptOggData
    case remuxFailed(String)
    case cancelled
}

final class OpusRemuxer {
    struct RemuxResult {
        let cafURL: URL
        let packetCount: Int
        let durationSeconds: TimeInterval
        let channelCount: Int
    }

    private var isCancelled = false

    func remux(source: URL, destination cafURL: URL) async throws -> RemuxResult {
        isCancelled = false

        let oggData: Data
        do {
            oggData = try Data(contentsOf: source)
        } catch {
            throw OpusRemuxerError.fileReadFailed
        }

        try Task.checkCancellation()

        let reader = OggPageReader(data: oggData)
        var writer: CAFOpusWriter?
        var audioData = Data()
        var lastGranule: Int64 = 0
        var packetsExtracted = 0
        var headerPacketsSeen = 0

        while !reader.isAtEnd {
            try Task.checkCancellation()

            guard let header = try reader.nextPageHeader() else {
                break
            }

            let payload = reader.readPagePayload(header)

            if header.isBeginningOfStream {
                reader.advancePastHeader(header)
                // Skip BOS page - it contains header packets which we handle
                // Actually, read the packets from the BOS page
                continue
            }

            reader.advancePastHeader(header)

            if payload.isEmpty { continue }

            let packets = reader.readPacketsInPage(header, payload: payload)

            for packet in packets {
                try Task.checkCancellation()

                if writer == nil {
                    // Look for OpusHead
                    if (try? OggPageReader.parseOpusHead(from: packet)) != nil {
                        let head = try OggPageReader.parseOpusHead(from: packet)
                        writer = CAFOpusWriter(opusHead: head)
                        headerPacketsSeen += 1
                        continue
                    }
                } else if headerPacketsSeen == 1 {
                    // Second packet should be OpusTags
                    if OggPageReader.isOpusTagsMagic(packet) {
                        headerPacketsSeen += 1
                        continue
                    }
                }

                guard let w = writer, headerPacketsSeen >= 2 else {
                    continue
                }

                audioData.append(packet)
                w.writeOpusPacket(packet)
                packetsExtracted += 1
            }

            if header.granulePosition > 0 {
                lastGranule = header.granulePosition
            }
        }

        try Task.checkCancellation()

        guard let w = writer, packetsExtracted > 0 else {
            try? FileManager.default.removeItem(at: cafURL)
            throw OpusRemuxerError.noOpusStream
        }

        do {
            try w.write(to: cafURL, lastGranulePosition: lastGranule, audioData: audioData)
        } catch {
            try? FileManager.default.removeItem(at: cafURL)
            throw OpusRemuxerError.remuxFailed(error.localizedDescription)
        }

        return RemuxResult(
            cafURL: cafURL,
            packetCount: packetsExtracted,
            durationSeconds: Double(totalFrameCount(from: w, lastGranule: lastGranule)) / 48000.0,
            channelCount: Int(w.opusHead.channelCount)
        )
    }

    func cancel() {
        isCancelled = true
    }

    private func totalFrameCount(from writer: CAFOpusWriter, lastGranule: Int64) -> Int64 {
        let preSkip = Int64(writer.opusHead.preSkip)
        let total = lastGranule - preSkip
        return total > 0 ? total : 0
    }
}
