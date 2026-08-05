import Foundation

/// Single source of truth for the URL that defines a chapter's audio cache
/// identity on the phone and the watch (INV-B). Every caller that downloads,
/// plays, caches, or transfers a chapter's audio MUST key on
/// `ChapterAudioIdentity.cacheKey(for:)` so phone downloader, phone player,
/// watch store, and phone→watch transfer agree by construction.
///
/// The canonical URL deliberately does NOT prefer the `opusURL` rendition:
/// AVFoundation cannot decode raw Ogg/Opus (`WatchPlaybackEngine` is a plain
/// `AVPlayer`), so downloads and transfers must use the rendition the player
/// engines can actually decode. If Opus is ever desired on the watch, gate the
/// opus branch behind a capability flag that is only true once the watch engine
/// can decode the container (CAF-wrapped Opus decodes; raw Ogg/Opus does not).
public enum ChapterAudioIdentity {
    /// The single URL that defines a chapter's cache identity everywhere.
    public static func canonicalURL(for chapter: Chapter) -> URL? {
        chapter.resolvedPlayableURL()
    }

    /// The cache key every store should use for this chapter's audio.
    public static func cacheKey(for chapter: Chapter) -> String? {
        canonicalURL(for: chapter).map(StreamCacheUtils.key(for:))
    }
}
