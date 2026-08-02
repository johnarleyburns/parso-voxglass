import Foundation
import VoxglassCore

/// Deterministic `AudioTranscoding` fake for Studio export tests (§19.2).
///
/// Writes a small file to `output` so hashes and byte counts behave like the
/// real pipeline, and reports scripted `measured` metrics when provided —
/// without touching LAME, libFLAC, or AVFoundation encode. This lets the
/// Export wizard model drive the real package builders in tests.
public struct FakeTranscoder: AudioTranscoding {

    public var availableEncoders: Set<Codec>
    public var measured: AudioQualityMetrics?

    public init(
        availableEncoders: Set<Codec> = [.mp3, .flac, .pcm, .aacLC, .alac],
        measured: AudioQualityMetrics? = nil
    ) {
        self.availableEncoders = availableEncoders
        self.measured = measured
    }

    public func transcode(
        input: URL,
        to spec: AudioSpec,
        tags: AudioTags,
        output: URL,
        progress: @Sendable (Double) -> Void
    ) async throws -> ExportedFile {
        progress(1)
        try copyOrWrite(from: input, to: output)
        return ExportedFile(
            url: output,
            role: .chapter,
            byteCount: size(of: output),
            sha256: try SHA256Hex.hex(contentsOf: output),
            measured: measured
        )
    }

    public func concatenate(
        _ inputs: [URL],
        to spec: AudioSpec,
        chapters: [ChapterMark]?,
        tags: AudioTags,
        output: URL
    ) async throws -> ExportedFile {
        try Data([0x6D, 0x34, 0x61]).write(to: output) // "m4a" placeholder
        return ExportedFile(
            url: output,
            role: .chapter,
            byteCount: 3,
            sha256: try SHA256Hex.hex(contentsOf: output),
            measured: measured
        )
    }

    public func master(
        input: URL,
        target: MasteringTarget,
        output: URL
    ) async throws -> ExportedFile {
        try copyOrWrite(from: input, to: output)
        return ExportedFile(
            url: output,
            role: .master,
            byteCount: size(of: output),
            sha256: try SHA256Hex.hex(contentsOf: output),
            measured: measured
        )
    }

    // MARK: - Helpers

    private func copyOrWrite(from input: URL, to output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        if FileManager.default.fileExists(atPath: input.path) {
            try FileManager.default.copyItem(at: input, to: output)
        } else {
            try Data("fake-transcoder".utf8).write(to: output)
        }
    }

    private func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
