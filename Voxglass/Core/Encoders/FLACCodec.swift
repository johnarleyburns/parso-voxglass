import Foundation
import VoxglassCore

/// The single libFLAC composition point used by import, preview, and export.
/// Keeping the decoder and encoder behind this value makes it difficult for a
/// caller to accidentally route FLAC through AVFoundation on one platform.
public struct FLACCodec: Sendable {
    public let decoder: FLACDecoder
    public let encoder: FLACEncoder

    public init(decoder: FLACDecoder = FLACDecoder(), encoder: FLACEncoder = FLACEncoder()) {
        self.decoder = decoder
        self.encoder = encoder
    }

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        try await decoder.describe(url)
    }

    public func decode(_ url: URL, targetSampleRate: Double? = nil) async throws -> DecodedAudio {
        try await decoder.decodeToMonoFloat(url, targetSampleRate: targetSampleRate)
    }

    public func decode(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double? = nil
    ) async throws -> DecodedAudio {
        try await decoder.decodeToMonoFloat(url, range: range, targetSampleRate: targetSampleRate)
    }

    @discardableResult
    public func encode(
        samples: [Float],
        sampleRate: Double,
        channels: Int = 1,
        bitDepth: Int = 16,
        tags: AudioTags? = nil,
        to outputURL: URL
    ) throws -> Int {
        try encoder.encode(
            samples: samples,
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: bitDepth,
            tags: tags ?? AudioTags(title: "", artist: "", album: ""),
            to: outputURL
        )
    }
}
