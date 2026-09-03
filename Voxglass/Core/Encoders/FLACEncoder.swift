import Foundation
import ParsoAudioCore
import VoxglassCore

/// FLAC delivery encoder — a thin shim over `ParsoAudioCore` (vendored libFLAC
/// 1.4.3, compiled with `--verify`). Produces a standard 16/24-bit FLAC with
/// Vorbis comments (§16.6); the `FLAC.xcframework` binary dependency is gone.
///
/// FLAC is lossless; the delivered file is bit-exact on decode.
public struct FLACEncoder: Sendable {

    public init() {}

    /// Encode `samples` (mono float) at `sampleRate`/`bitDepth` into a FLAC
    /// file at `outputURL`, writing `tags` as Vorbis comments. Returns the
    /// number of bytes written.
    public func encode(
        samples: [Float],
        sampleRate: Double,
        channels: Int,
        bitDepth: Int,
        tags: AudioTags,
        to outputURL: URL
    ) throws -> Int {
        guard channels == 1 else {
            // The pipeline is mono end to end; a stereo spec is a caller error.
            throw TranscodeError.unsupportedSpec(
                AudioSpec(container: .flac, codec: .flac, channels: channels, bitDepth: bitDepth)
            )
        }
        try? FileManager.default.removeItem(at: outputURL)

        let format = AudioFormat(sampleRate: sampleRate, channelCount: 1)
        let buffer = PCMBuffer(format: format, capacity: samples.count)
        let channel = buffer.channel(0)
        for i in 0..<samples.count { channel[i] = samples[i] }

        do {
            let writer = try AudioFileWriter(
                url: outputURL, format: format,
                codec: .flacDelivery(bitDepth: bitDepth, compression: 5, tags: Self.vorbisComments(tags))
            )
            try writer.write(buffer)
            try writer.finish()
        } catch let error as AudioFileError {
            throw TranscodeError.encoderFailed(status: 0, stderr: "\(error)")
        }

        return (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
    }

    // MARK: - Vorbis comments

    static func vorbisComments(_ tags: AudioTags) -> [FLACVorbisComment] {
        var comments: [FLACVorbisComment] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            comments.append(FLACVorbisComment(key: key, value: value))
        }
        add("TITLE", tags.title)
        add("ARTIST", tags.artist)
        add("ALBUM", tags.album)
        add("TRACKNUMBER", tags.track.map { $0.1 > 0 ? "\($0.0)/\($0.1)" : "\($0.0)" })
        add("DATE", tags.year.map(String.init))
        add("GENRE", tags.genre)
        add("DESCRIPTION", tags.description)
        add("COPYRIGHT", tags.copyright)
        add("PERFORMER", tags.narrator)
        return comments
    }
}
