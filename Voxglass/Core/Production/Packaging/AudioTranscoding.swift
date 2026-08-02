import Foundation

// MARK: - AudioTranscoding

/// The encoding seam of the export pipeline (§16.1, §16.2). Core codec work is
/// provided by `VoxTranscoder` (Studio/encoders target): AVFoundation for
/// decode and for AAC/ALAC/PCM, plus the bundled LAME (MP3) and libFLAC
/// encoders (§16.3). Builders depend only on this protocol, so they stay pure
/// and testable with fakes.
public protocol AudioTranscoding: Sendable {
    /// The codecs this transcoder can *encode* right now. A builder MUST check
    /// this before doing any work and fail with `PackagingError.encoderUnavailable`
    /// when its destination's codec is missing (§16.3, `TranscoderAvailabilityTests`).
    var availableEncoders: Set<Codec> { get }

    /// Encode one input audio file to `spec` at `output`, tagging it with `tags`.
    /// The output must conform exactly to `spec` (sample rate, channels, bitrate,
    /// CBR flag) so a downstream frame-header inspection can prove conformance.
    func transcode(
        input: URL,
        to spec: AudioSpec,
        tags: AudioTags,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ExportedFile

    /// Concatenate `inputs` into a single file at `output` per `spec`
    /// (chapterized M4B for retail, §3.4.4), with optional chapter marks and
    /// tags embedded.
    func concatenate(
        _ inputs: [URL],
        to spec: AudioSpec,
        chapters: [ChapterMark]?,
        tags: AudioTags,
        output: URL
    ) async throws -> ExportedFile

    /// Apply the mastering chain (§16.7) to a rendered lossless file and write
    /// a mastered lossless file (retail destinations only, when
    /// `ExportOptions.applyMastering` is on). The builder calls this *before*
    /// transcoding to the destination format; the chain needs the float PCM
    /// that only a real decoder can provide, so it lives with the encoder.
    func master(
        input: URL,
        target: MasteringTarget,
        output: URL
    ) async throws -> ExportedFile
}

// MARK: - TranscodeError

public enum TranscodeError: Error, Sendable, Equatable {
    /// The requested codec is not available on this build (§16.3).
    case encoderUnavailable(String)
    /// `AudioSpec` cannot be produced (unknown container/codec combination).
    case unsupportedSpec(AudioSpec)
    /// The encoder returned a failure status (LAME/FLAC/ffmpeg exit code).
    case encoderFailed(status: Int, stderr: String?)
    /// The input file could not be decoded to PCM.
    case decodeFailed(URL)
    /// Memory could not be allocated for a buffer.
    case bufferAllocation
    /// A required encoder library call failed.
    case nativeLibrary(String)
}
