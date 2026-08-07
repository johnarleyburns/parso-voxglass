import Foundation

/// The decode seam of the audio pipeline (§11.5, §16.3). Implementations turn
/// an audio file into mono float PCM; FLAC MUST go through `FLACDecoder`
/// (libFLAC) on both macOS and iPhone rather than relying on platform FLAC
/// behavior.
public protocol AudioDecoding: Sendable {
    func describe(_ url: URL) async throws -> AudioFormatDescription
    func decodeToMonoFloat(_ url: URL, targetSampleRate: Double?) async throws -> DecodedAudio
}

public struct DecodedAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: TimeInterval

    public init(samples: [Float], sampleRate: Double, duration: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.duration = duration
    }
}

/// A contiguous slice of a source audio file, expressed in **source-file**
/// sample frames *before* any resampling (§11.5).
public struct AudioDecodeRange: Sendable, Equatable {
    /// First source-file sample frame of the range.
    public var startFrame: Int64
    /// Number of source-file sample frames before resampling.
    public var frameCount: Int

    public init(startFrame: Int64, frameCount: Int) {
        self.startFrame = startFrame
        self.frameCount = frameCount
    }
}

/// An `AudioDecoding` that can decode an arbitrary contiguous range without
/// touching the rest of the file (§11.5).
///
/// Interactive workflows (record/review playback, paragraph seek, trim
/// preview, imported-audio splitting preview, any "jump to time" action) MUST
/// use this range path for large files and MUST NOT decode the whole file just
/// to reach a later position. Full-file decode is allowed only for explicit
/// whole-asset analysis, rendering, transcoding, or export steps.
public protocol SeekableAudioDecoding: AudioDecoding {
    /// Decode `range` (source-file sample frames) to mono float PCM, optionally
    /// resampling to `targetSampleRate`. Implementations decode the requested
    /// range plus only the bounded lookahead needed for resampling and fades.
    ///
    /// If the source cannot be positioned (non-seekable stream), implementations
    /// MUST throw a specific non-seekable error (e.g.
    /// `TranscodeError.fileNotSeekable`) rather than silently falling back to a
    /// full-file decode.
    func decodeToMonoFloat(
        _ url: URL,
        range: AudioDecodeRange,
        targetSampleRate: Double?
    ) async throws -> DecodedAudio
}
