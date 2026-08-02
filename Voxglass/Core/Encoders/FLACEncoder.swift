import FLAC
import Foundation
import VoxglassCore

/// Thin Swift wrapper over the libFLAC C API (§16.3).
///
/// FLAC is lossless; the delivered file must be bit-exact on decode. libFLAC
/// is compiled with `--verify` enabled and the wrapper calls
/// `FLAC__stream_encoder_set_verify` so the encoder self-checks every frame
/// against the original PCM before finishing.
public struct FLACEncoder: Sendable {

    public init() {}

    /// Encode `samples` (mono float) at `sampleRate`/`bitDepth` into a FLAC
    /// file at `outputURL`, writing `tags` as Vorbis comments (§16.6).
    /// Returns the number of bytes written.
    public func encode(
        samples: [Float],
        sampleRate: Double,
        channels: Int,
        bitDepth: Int,
        tags: AudioTags,
        to outputURL: URL
    ) throws -> Int {
        guard let encoder = FLAC__stream_encoder_new() else {
            throw TranscodeError.nativeLibrary("FLAC__stream_encoder_new")
        }
        defer { FLAC__stream_encoder_delete(encoder) }

        FLAC__stream_encoder_set_channels(encoder, FLAC__uint32(channels))
        FLAC__stream_encoder_set_bits_per_sample(encoder, FLAC__uint32(bitDepth))
        FLAC__stream_encoder_set_sample_rate(encoder, FLAC__uint32(sampleRate))
        FLAC__stream_encoder_set_compression_level(encoder, 5)
        FLAC__stream_encoder_set_verify(encoder, 1)

        var metadata: UnsafeMutablePointer<FLAC__StreamMetadata>?
        if let comments = vorbisComments(tags) {
            metadata = comments
            FLAC__stream_encoder_set_metadata(encoder, &metadata, 1)
        }
        defer {
            if let metadata { FLAC__metadata_object_delete(metadata) }
        }

        let status = FLAC__stream_encoder_init_file(encoder, outputURL.path, nil, nil)
        guard status == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            throw TranscodeError.encoderFailed(status: Int(status.rawValue), stderr: "FLAC init status \(status.rawValue)")
        }

        let scale = Double(1 << (bitDepth - 1))
        var pcm: [FLAC__int32] = samples.map { sample in
            FLAC__int32(max(-1.0, min(1.0, Double(sample))) * scale)
        }

        let processed = FLAC__stream_encoder_process_interleaved(encoder, &pcm, FLAC__uint32(samples.count))
        let finished = FLAC__stream_encoder_finish(encoder)
        guard processed != 0, finished != 0 else {
            throw TranscodeError.encoderFailed(status: Int(FLAC__stream_encoder_get_state(encoder).rawValue), stderr: "FLAC process/finish failed")
        }
        return (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
    }

    // MARK: - Vorbis comments

    private func vorbisComments(_ tags: AudioTags) -> UnsafeMutablePointer<FLAC__StreamMetadata>? {
        guard let meta = FLAC__metadata_object_new(FLAC__METADATA_TYPE_VORBIS_COMMENT) else { return nil }
        var failed = false

        func add(_ name: String, _ value: String?) {
            guard !failed, let value, !value.isEmpty else { return }
            var entry = FLAC__StreamMetadata_VorbisComment_Entry()
            guard FLAC__metadata_object_vorbiscomment_entry_from_name_value_pair(&entry, name, value) != 0 else {
                failed = true
                return
            }
            guard FLAC__metadata_object_vorbiscomment_append_comment(meta, entry, 1) != 0 else {
                failed = true
                return
            }
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

        if failed {
            FLAC__metadata_object_delete(meta)
            return nil
        }
        return meta
    }
}
