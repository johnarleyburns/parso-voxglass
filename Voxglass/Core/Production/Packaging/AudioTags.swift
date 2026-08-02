import Foundation

// MARK: - ChapterMark

/// A chapter marker for chapterized output (§16.8, §3.4.4). `start` is the
/// offset in seconds from the start of the concatenated audio.
public struct ChapterMark: Sendable, Equatable, Hashable {
    public var title: String
    public var start: TimeInterval

    public init(title: String, start: TimeInterval) {
        self.title = title
        self.start = start
    }
}

// MARK: - AudioTags

/// The metadata written into a delivered audio file (§16.6). The container
/// writers (`ID3Writer`, MPEG-4 atoms, Vorbis comments) each project the subset
/// of fields their format supports; `TaggingTests` round-trips every container.
public struct AudioTags: Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var composer: String?
    public var track: (Int, Int)?
    public var disc: (Int, Int)?
    public var year: Int?
    public var genre: String
    public var comment: String?
    public var copyright: String?
    public var narrator: String?
    public var publisher: String?
    public var language: String?
    public var description: String?
    public var artworkJPEG: Data?
    public var isAudiobook: Bool
    public var chapters: [ChapterMark]?

    public init(
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        composer: String? = nil,
        track: (Int, Int)? = nil,
        disc: (Int, Int)? = nil,
        year: Int? = nil,
        genre: String = "Speech",
        comment: String? = nil,
        copyright: String? = nil,
        narrator: String? = nil,
        publisher: String? = nil,
        language: String? = nil,
        description: String? = nil,
        artworkJPEG: Data? = nil,
        isAudiobook: Bool = false,
        chapters: [ChapterMark]? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.composer = composer
        self.track = track
        self.disc = disc
        self.year = year
        self.genre = genre
        self.comment = comment
        self.copyright = copyright
        self.narrator = narrator
        self.publisher = publisher
        self.language = language
        self.description = description
        self.artworkJPEG = artworkJPEG
        self.isAudiobook = isAudiobook
        self.chapters = chapters
    }

    /// Maps an ISO 639-1/2 hyphenated locale ("en-US") to the 3-letter code the
    /// tagging formats expect ("eng"). Falls back to the input unchanged.
    public static func iso639Code(from locale: String?) -> String? {
        guard let locale, !locale.isEmpty else { return nil }
        let parts = locale.split(separator: "-")
        guard let first = parts.first else { return nil }
        let code = String(first).lowercased()
        let map = ["en": "eng", "de": "deu", "fr": "fra", "es": "spa", "it": "ita",
                   "pt": "por", "nl": "nld", "ru": "rus", "ja": "jpn", "zh": "zho",
                   "ko": "kor", "ar": "ara", "el": "ell", "sv": "swe", "da": "dan",
                   "no": "nor", "fi": "fin", "pl": "pol", "cs": "ces", "hu": "hun",
                   "tr": "tur", "he": "heb", "hi": "hin", "la": "lat"]
        return map[code] ?? code
    }
}

extension AudioTags: Equatable {
    public static func == (lhs: AudioTags, rhs: AudioTags) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
            && lhs.albumArtist == rhs.albumArtist && lhs.composer == rhs.composer
            && lhs.track?.0 == rhs.track?.0 && lhs.track?.1 == rhs.track?.1
            && lhs.disc?.0 == rhs.disc?.0 && lhs.disc?.1 == rhs.disc?.1
            && lhs.year == rhs.year && lhs.genre == rhs.genre && lhs.comment == rhs.comment
            && lhs.copyright == rhs.copyright && lhs.narrator == rhs.narrator
            && lhs.publisher == rhs.publisher && lhs.language == rhs.language
            && lhs.description == rhs.description && lhs.artworkJPEG == rhs.artworkJPEG
            && lhs.isAudiobook == rhs.isAudiobook && lhs.chapters == rhs.chapters
    }
}
