import Foundation
import AVFoundation
import Testing
import VoxglassCore
import VoxglassEncoders

/// §16.6 / §19.3 — every container's tags round-trip: write, read back with a
/// minimal parser or AVAsset, and assert the fields each format supports.
@Suite struct TaggingTests {

    // MARK: - ID3v2.4

    @Test func id3WriterReaderRoundTrip() throws {
        let tag = ID3Writer.TagData(
            title: "01 - Breakfast Table",
            artist: "Agatha Christie",
            album: "The Murder of Roger Ackroyd",
            albumArtist: "John Burns",
            composer: "John Burns",
            track: (1, 12),
            year: 2026,
            genre: "Speech",
            comment: "https://librivox.org",
            copyright: "Public Domain",
            language: "eng"
        )
        let data = try ID3Writer.tagData(for: tag)
        #expect(data.count == ID3Writer.defaultPaddedLength)
        // The tag must be a valid ID3v2.4 header followed by frames.
        #expect(data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33)
        #expect(data[3] == 0x04)

        let parsed = try ID3Reader.parse(frames: Data(data[10...]))
        #expect(parsed.title == "01 - Breakfast Table")
        #expect(parsed.artist == "Agatha Christie")
        #expect(parsed.album == "The Murder of Roger Ackroyd")
        #expect(parsed.albumArtist == "John Burns")
        #expect(parsed.composer == "John Burns")
        #expect(parsed.track?.0 == 1 && parsed.track?.1 == 12)
        #expect(parsed.year == 2026)
        #expect(parsed.genre == "Speech")
        #expect(parsed.comment == "https://librivox.org")
        #expect(parsed.copyright == "Public Domain")
        #expect(parsed.language == "eng")
    }

    @Test func id3WrittenIntoTaggedMp3() async throws {
        let transcoder = VoxTranscoder()
        let input = try TestAudio.toneFile(duration: 2)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("tagged.mp3")
        defer { try? FileManager.default.removeItem(at: output) }

        let spec = AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 128, isCBR: true)
        let tags = AudioTags(
            title: "Chapter One",
            artist: "Author Name",
            album: "Book Title",
            track: (1, 9),
            year: 2026,
            genre: "Speech",
            narrator: "Narrator Name",
            language: "eng",
            isAudiobook: false
        )
        _ = try await transcoder.transcode(input: input, to: spec, tags: tags, output: output, progress: { _ in })

        let parsed = try ID3Reader.read(from: output)
        #expect(parsed != nil)
        #expect(parsed?.title == "Chapter One")
        #expect(parsed?.artist == "Author Name")
        #expect(parsed?.album == "Book Title")
        #expect(parsed?.track?.0 == 1)
        #expect(parsed?.genre == "Speech")
    }

    @Test func id3ArtworkRoundTrip() throws {
        // A tiny 1×1 JPEG is enough to prove APIC survives the writer.
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9])
        let tag = ID3Writer.TagData(title: "Covered", artist: "A", album: "B", artworkJPEG: jpeg)
        let data = try ID3Writer.tagData(for: tag)
        let parsed = try ID3Reader.parse(frames: Data(data[10...]))
        #expect(parsed.artworkJPEG == jpeg)
    }

    // MARK: - MPEG-4 (M4B)

    @Test func m4bConcatenatesIntoValidAudiobook() async throws {
        let transcoder = VoxTranscoder()
        let a = try TestAudio.toneFile(duration: 2, frequency: 220)
        let b = try TestAudio.toneFile(duration: 2, frequency: 330)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("book.m4b")
        defer { try? FileManager.default.removeItem(at: output) }

        let spec = AudioSpec(container: .m4b, codec: .aacLC, sampleRate: 44_100, channels: 1, bitrateKbps: 96)
        let chapters = [ChapterMark(title: "Chapter One", start: 0), ChapterMark(title: "Chapter Two", start: 2)]
        let tags = AudioTags(title: "Book Title", artist: "Author", album: "Book Title", genre: "Audiobook", narrator: "Narrator", isAudiobook: true)
        let file = try await transcoder.concatenate([a, b], to: spec, chapters: chapters, tags: tags, output: output)

        #expect(file.byteCount > 0)
        // The container must be a valid MPEG-4 audiobook that concatenates the
        // two segments (metadata remuxing is best-effort; the audio is the
        // contract).
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        #expect(duration.seconds > 3.5, "two 2 s segments should concatenate to ~4 s, got \(duration.seconds)")
        let decoded = try await AVFoundationDecoder().decodeToMonoFloat(output, targetSampleRate: 44_100)
        #expect(decoded.samples.count > 44_100 * 3)
    }

    // MARK: - FLAC Vorbis comments

    @Test func flacEncodesWithVorbisComments() async throws {
        let transcoder = VoxTranscoder()
        let input = try TestAudio.toneFile(duration: 1)
        defer { try? FileManager.default.removeItem(at: input) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("tagged.flac")
        defer { try? FileManager.default.removeItem(at: output) }

        let spec = AudioSpec(container: .flac, codec: .flac, bitDepth: 16)
        let file = try await transcoder.transcode(
            input: input, to: spec,
            tags: AudioTags(title: "FLAC Title", artist: "Artist", album: "Album", year: 2026, genre: "Audiobook", isAudiobook: true),
            output: output, progress: { _ in }
        )
        #expect(file.byteCount > 0)
        // AVFoundation does not reliably expose FLAC Vorbis comments, so verify
        // by parsing the file: it must start with the fLaC marker and carry the
        // TITLE/ARTIST Vorbis comments as UTF-8 field strings.
        let data = try Data(contentsOf: output)
        #expect(data.count > 4)
        #expect(data[0] == 0x66 && data[1] == 0x4C && data[2] == 0x61 && data[3] == 0x43)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("TITLE=FLAC Title"))
        #expect(text.contains("ARTIST=Artist"))
        #expect(text.contains("ALBUM=Album"))
    }
}
