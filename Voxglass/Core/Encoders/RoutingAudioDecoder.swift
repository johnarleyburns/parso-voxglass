import Foundation
import VoxglassCore

/// The composition point for **decode** (§16.3): FLAC files are decoded
/// through libFLAC (`FLACDecoder`) on macOS and iPhone, and everything else
/// (CAF, WAV, MP3, M4A/AAC, AIFF) through AVFoundation. MP3 decode stays
/// AVFoundation-backed; the FLAC path never depends on platform FLAC behavior.
///
/// Conforms to `SeekableAudioDecoding` so interactive seek/preview paths get
/// bounded range decode for FLAC (libFLAC `seek_absolute`) and for
/// AVFoundation formats (`AVAudioFile.framePosition`) alike.
public struct RoutingAudioDecoder: SeekableAudioDecoding {

    public var flacDecoder: any SeekableAudioDecoding
    public var fallback: any SeekableAudioDecoding

    public init(
        flacDecoder: any SeekableAudioDecoding = FLACDecoder(),
        fallback: any SeekableAudioDecoding = AVFoundationDecoder()
    ) {
        self.flacDecoder = flacDecoder
        self.fallback = fallback
    }

    // MARK: - AudioDecoding

    public func describe(_ url: URL) async throws -> AudioFormatDescription {
        try await decoder(for: url).describe(url)
    }

    public func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio {
        try await decoder(for: url).decodeToMonoFloat(url, targetSampleRate: targetSampleRate)
    }

    // MARK: - SeekableAudioDecoding

    public func decodeToMonoFloat(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> DecodedAudio {
        try await decoder(for: url).decodeToMonoFloat(url, range: range, targetSampleRate: targetSampleRate)
    }

    // MARK: - Routing

    private func decoder(for url: URL) -> any SeekableAudioDecoding {
        isFLAC(url) ? flacDecoder : fallback
    }

    /// `true` if `url` carries the FLAC magic number `fLaC` (§11.5: FLAC input
    /// MUST be decoded through libFLAC). The file extension is a fallback for
    /// files that cannot be opened.
    private func isFLAC(_ url: URL) -> Bool {
        let extensionIsFLAC = url.pathExtension.lowercased() == "flac"
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return extensionIsFLAC
        }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else {
            return extensionIsFLAC
        }
        return head == Data([0x66, 0x4C, 0x61, 0x43]) // "fLaC"
    }
}
