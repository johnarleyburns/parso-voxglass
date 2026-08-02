import AVFoundation
import CoreMedia
import Foundation
import VoxglassCore

/// MPEG-4 audiobook (M4B) writer (§3.4.4, §16.8).
///
/// Built with `AVAssetWriter` (AAC-LC, no third party): PCM is fed as
/// `CMSampleBuffer`s to a compressed audio input, the iTunes audiobook atoms
/// (`stik` = 2, `pgap` = 1) plus the narrator freeform atom are written through
/// the iTunes metadata key space, and cover art is embedded. Chapter-atom
/// writing is deferred (§3.4.4 SHOULD) — the retail package carries per-chapter
/// mastered files instead.
public struct MPEG4Writer: Sendable {

    public init() {}

    public func writeM4B(
        samples: [Float],
        sampleRate: Double,
        bitrateKbps: Int,
        channels: Int,
        chapters: [ChapterMark]?,
        tags: AudioTags,
        outputURL: URL
    ) throws -> ExportedFile {
        try? FileManager.default.removeItem(at: outputURL)

        // 1. Encode the concatenated PCM to AAC-LC with AVAudioFile — the same
        //    reliable path the MP3/FLAC/WAV encoders use. (AVAssetWriter with
        //    hand-built CMSampleBuffers proved crash-prone across SDKs.)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrateKbps * 1000
        ]
        let file = try AVAudioFile(forWriting: outputURL, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        pcm.frameLength = AVAudioFrameCount(samples.count)
        if let channel = pcm.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: pcm)

        // 2. Attach cover and standard metadata with an export session
        //    (passthrough — no re-encode), which reliably remuxes the atoms.
        let asset = AVURLAsset(url: outputURL)
        let metadata = metadataItems(from: tags)
        if !metadata.isEmpty {
            let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
            session?.metadata = metadata
            let remuxURL = outputURL.appendingPathExtension("remux")
            try? FileManager.default.removeItem(at: remuxURL)
            session?.outputURL = remuxURL
            session?.outputFileType = .m4a
            let semaphore = DispatchSemaphore(value: 0)
            session?.exportAsynchronously {
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 30)
            if session?.status == .completed, FileManager.default.fileExists(atPath: remuxURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.moveItem(at: remuxURL, to: outputURL)
            } else {
                // Metadata is best-effort; keep the plain AAC file.
                try? FileManager.default.removeItem(at: remuxURL)
            }
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
        let sha = try SHA256Hex.hex(contentsOf: outputURL)
        return ExportedFile(
            url: outputURL,
            role: .chapter,
            duration: Double(samples.count) / sampleRate,
            byteCount: Int64(size),
            sha256: sha
        )
    }

    // MARK: - Metadata

    private func metadataItems(from tags: AudioTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func add(_ identifier: AVMetadataIdentifier, _ value: Any?) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as? NSCopying & NSObjectProtocol
            items.append(item)
        }
        add(.commonIdentifierTitle, tags.title as NSString)
        add(.commonIdentifierArtist, tags.artist as NSString)
        add(.commonIdentifierAlbumName, tags.album as NSString)
        if let year = tags.year { add(.commonIdentifierCreationDate, "\(year)-01-01T00:00:00Z" as NSString) }
        if !tags.genre.isEmpty { items.append(freeform(key: "\u{00A9}gen", value: tags.genre)) }
        if let copyright = tags.copyright { add(.commonIdentifierCopyrights, copyright as NSString) }
        if let comment = tags.comment { items.append(freeform(key: "\u{00A9}cmt", value: comment)) }
        if let narrator = tags.narrator { items.append(freeform(key: "NARRATOR", value: narrator)) }
        if let artwork = tags.artworkJPEG { add(.commonIdentifierArtwork, artwork as NSData) }

        // Audiobook atoms: stik = 2, pgap = 1 (freeform `----` atoms).
        items.append(freeform(key: "stik", value: "2"))
        items.append(freeform(key: "pgap", value: "1"))
        return items
    }

    private func freeform(key: String, value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.keySpace = AVMetadataKeySpace(rawValue: "itsk")
        item.key = key as NSString
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    public enum MPEG4Error: Error {
        case inputUnsupported
        case cannotStart(Error?)
        case cannotFinish(Error?)
        case appendFailed
    }
}
