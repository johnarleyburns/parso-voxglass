import Foundation

/// ID3v2.4 tag writer and minimal reader (§16.6).
///
/// LAME writes only the Xing header, not an ID3 tag, so Voxglass writes its own
/// ID3v2.4 tag at the head of every MP3 it ships. The tag is written into a
/// padded 4 KB area so a later retag rewrites only the tag, never the audio
/// frames (§16.6). Text is UTF-8 (encoding byte `0x03`).
///
/// Frames written: `TIT2 TPE1 TALB TPE2 TCOM TRCK TDRC TCON TLAN TCOP COMM APIC`.
public enum ID3Writer {

    public static let defaultPaddedLength = 4096

    /// The frame data for `tags` (LibriVox/retail conventions per §16.6).
    public struct TagData {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var albumArtist: String?
        public var composer: String?
        public var track: (Int, Int)?
        public var year: Int?
        public var genre: String?
        public var comment: String?
        public var copyright: String?
        public var language: String?
        public var artworkJPEG: Data?

        public init(
            title: String? = nil,
            artist: String? = nil,
            album: String? = nil,
            albumArtist: String? = nil,
            composer: String? = nil,
            track: (Int, Int)? = nil,
            year: Int? = nil,
            genre: String? = nil,
            comment: String? = nil,
            copyright: String? = nil,
            language: String? = nil,
            artworkJPEG: Data? = nil
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.albumArtist = albumArtist
            self.composer = composer
            self.track = track
            self.year = year
            self.genre = genre
            self.comment = comment
            self.copyright = copyright
            self.language = language
            self.artworkJPEG = artworkJPEG
        }
    }

    /// Build the full ID3v2.4 tag bytes: 10-byte header + frames + zero padding
    /// to `paddedLength`. The returned `Data` is exactly `paddedLength` bytes.
    public static func tagData(for tag: TagData, paddedLength: Int = defaultPaddedLength) throws -> Data {
        var frameBytes = Data()
        try appendTextFrame("TIT2", tag.title, to: &frameBytes)
        try appendTextFrame("TPE1", tag.artist, to: &frameBytes)
        try appendTextFrame("TALB", tag.album, to: &frameBytes)
        try appendTextFrame("TPE2", tag.albumArtist, to: &frameBytes)
        try appendTextFrame("TCOM", tag.composer, to: &frameBytes)
        if let track = tag.track {
            let value = track.1 > 0 ? "\(track.0)/\(track.1)" : "\(track.0)"
            try appendTextFrame("TRCK", value, to: &frameBytes)
        }
        if let year = tag.year {
            try appendTextFrame("TDRC", String(year), to: &frameBytes)
        }
        try appendTextFrame("TCON", tag.genre, to: &frameBytes)
        try appendTextFrame("TLAN", tag.language, to: &frameBytes)
        try appendTextFrame("TCOP", tag.copyright, to: &frameBytes)
        if let comment = tag.comment {
            try appendCommentFrame("COMM", comment, to: &frameBytes)
        }
        if let artwork = tag.artworkJPEG {
            try appendArtworkFrame("APIC", mime: "image/jpeg", data: artwork, to: &frameBytes)
        }

        let contentLength = frameBytes.count
        guard contentLength + 10 <= paddedLength else {
            throw ID3Error.tagExceedsPaddedArea(contentLength, paddedLength)
        }

        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        header.append(0x04)                            // major version 2.4
        header.append(0x00)                            // revision
        header.append(0x00)                            // flags
        header.append(contentsOf: syncsafe(Int32(paddedLength - 10)))

        var out = header
        out.append(frameBytes)
        let padding = paddedLength - out.count
        out.append(Data(repeating: 0, count: padding))
        return out
    }

    // MARK: - Frame builders

    private static func appendTextFrame(_ id: String, _ value: String?, to data: inout Data) throws {
        guard let value, !value.isEmpty else { return }
        var frame = Data()
        frame.append(0x03) // UTF-8
        frame.append(Data(value.utf8))
        appendFrame(id: id, payload: frame, to: &data)
    }

    private static func appendCommentFrame(_ id: String, _ value: String, to data: inout Data) throws {
        var frame = Data()
        frame.append(0x03)                  // UTF-8
        frame.append(Data("eng".utf8))      // language
        frame.append(0x00)                  // empty short description (terminated)
        frame.append(Data(value.utf8))
        appendFrame(id: id, payload: frame, to: &data)
    }

    private static func appendArtworkFrame(_ id: String, mime: String, data picture: Data, to data: inout Data) throws {
        var frame = Data()
        frame.append(0x03)                   // UTF-8
        frame.append(Data(mime.utf8))
        frame.append(0x00)                   // mime terminator
        frame.append(0x03)                   // picture type: front cover
        frame.append(0x00)                   // empty description (terminated)
        frame.append(picture)
        appendFrame(id: id, payload: frame, to: &data)
    }

    private static func appendFrame(id: String, payload: Data, to data: inout Data) {
        data.append(Data(id.utf8))
        data.append(contentsOf: syncsafe(Int32(payload.count)))
        data.append(contentsOf: [0x00, 0x00]) // frame flags
        data.append(payload)
    }

    /// Encodes a value in the synchsafe 7-bit style used by ID3v2 sizes.
    static func syncsafe(_ value: Int32) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F)
        ]
    }

    public enum ID3Error: Error, Equatable {
        case tagExceedsPaddedArea(Int, Int)
        case malformedTag
    }
}

// MARK: - ID3Reader

/// Minimal ID3v2 reader used by tests and re-validation (§16.6, TaggingTests).
/// Parses the text frames and COMM/APIC that `ID3Writer` writes.
public enum ID3Reader {

    public struct ParsedTag: Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var albumArtist: String?
        public var composer: String?
        public var track: (Int, Int)?
        public var year: Int?
        public var genre: String?
        public var comment: String?
        public var copyright: String?
        public var language: String?
        public var artworkJPEG: Data?
    }

    /// Read the ID3v2 tag from the head of an MP3 file.
    public static func read(from url: URL) throws -> ParsedTag? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 10), head.count == 10 else { return nil }
        guard head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return nil }
        let version = head[3]
        guard version >= 3 else { return nil }

        let size = unsyncsafe([head[6], head[7], head[8], head[9]])
        guard size > 0, let frameData = try handle.read(upToCount: size), frameData.count == size else {
            return nil
        }
        return try parse(frames: frameData)
    }

    /// Parse the frames in a raw ID3v2 frame area (no 10-byte header).
    public static func parse(frames frameData: Data) throws -> ParsedTag {
        var tag = ParsedTag()
        var cursor = 0
        let bytes = [UInt8](frameData)
        while cursor + 10 <= bytes.count {
            let frameID = String(bytes: Data(bytes[cursor ..< cursor + 4]), encoding: .ascii)
            guard let frameID, frameID.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) else { break }
            let size = unsyncsafe(Array(bytes[cursor + 4 ..< cursor + 8]))
            cursor += 10
            guard cursor + size <= bytes.count else { break }
            let payload = Array(bytes[cursor ..< cursor + size])
            cursor += size
            if payload.isEmpty { continue }

            switch frameID {
            case "TIT2": tag.title = text(payload)
            case "TPE1": tag.artist = text(payload)
            case "TALB": tag.album = text(payload)
            case "TPE2": tag.albumArtist = text(payload)
            case "TCOM": tag.composer = text(payload)
            case "TRCK":
                if let value = text(payload) {
                    let parts = value.split(separator: "/").compactMap { Int($0) }
                    tag.track = parts.count == 2 ? (parts[0], parts[1]) : (parts.first ?? 0, 0)
                }
            case "TDRC":
                if let value = text(payload) { tag.year = Int(value) }
            case "TCON": tag.genre = text(payload)
            case "TLAN": tag.language = text(payload)
            case "TCOP": tag.copyright = text(payload)
            case "COMM": tag.comment = comment(payload)
            case "APIC": tag.artworkJPEG = artwork(payload)
            default: break
            }
        }
        return tag
    }

    private static func text(_ payload: [UInt8]) -> String? {
        guard payload.count > 1 else { return nil }
        let body = Data(payload[1...])
        return String(data: body, encoding: .utf8)
    }

    private static func comment(_ payload: [UInt8]) -> String? {
        guard payload.count > 5 else { return nil }
        // [encoding][lang3][description 0x00][text]
        var cursor = 4
        if payload[cursor] == 0x00 {
            cursor += 1
        } else {
            while cursor < payload.count && payload[cursor] != 0x00 { cursor += 1 }
            if cursor < payload.count { cursor += 1 }
        }
        guard cursor < payload.count else { return nil }
        return String(data: Data(payload[cursor...]), encoding: .utf8)
    }

    private static func artwork(_ payload: [UInt8]) -> Data? {
        guard payload.count > 5 else { return nil }
        var cursor = 1 // encoding
        while cursor < payload.count && payload[cursor] != 0x00 { cursor += 1 }
        guard cursor < payload.count else { return nil }
        cursor += 1 // mime terminator
        guard cursor < payload.count else { return nil }
        cursor += 1 // picture type
        while cursor < payload.count && payload[cursor] != 0x00 { cursor += 1 }
        guard cursor < payload.count else { return nil }
        cursor += 1 // description terminator
        return cursor < payload.count ? Data(payload[cursor...]) : nil
    }

    private static func unsyncsafe(_ bytes: [UInt8]) -> Int {
        (Int(bytes[0]) << 21) | (Int(bytes[1]) << 14) | (Int(bytes[2]) << 7) | Int(bytes[3])
    }
}

extension ID3Reader.ParsedTag: Equatable {
    public static func == (lhs: ID3Reader.ParsedTag, rhs: ID3Reader.ParsedTag) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
            && lhs.albumArtist == rhs.albumArtist && lhs.composer == rhs.composer
            && lhs.track?.0 == rhs.track?.0 && lhs.track?.1 == rhs.track?.1
            && lhs.year == rhs.year && lhs.genre == rhs.genre && lhs.comment == rhs.comment
            && lhs.copyright == rhs.copyright && lhs.language == rhs.language
            && lhs.artworkJPEG == rhs.artworkJPEG
    }
}
