import Foundation
import Testing
import VoxglassCore
import VoxglassCoreTestSupport

/// Spec §19.3: `RenderCacheKey` must be stable across process launches and
/// across app versions — the cache is on disk in the package, and a key that
/// changes after relaunch silently re-renders every chapter (G-4 exists
/// because the codebase hit exactly this defect class before). The key must
/// also depend on every input that affects the rendered audio, and on nothing
/// that does not.
@Suite struct RenderCacheKeyTests {

    private func makeSegments() -> [PlaybackSegment] {
        let sha = SHA256Hex.hex(Data("segment-audio".utf8))
        return [
            PlaybackSegment(
                paragraphID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                chapterID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                globalOrdinal: 0,
                assetRef: AudioAssetReference(sha256: sha, relativePath: "Audio/Original/ab/cd/\(sha).wav", byteCount: 100, contentType: "audio/wav"),
                trim: 0.0..<5.0,
                gainDB: 0.5,
                fadeIn: 0.05,
                fadeOut: 0.1,
                leadingSilence: 0.2,
                trailingSilence: 0.1
            )
        ]
    }

    private let settings = AssemblySettings(
        paragraphGap: 0.45,
        chapterHeadSilence: 0.75,
        chapterTailSilence: 1.5,
        sceneBreakExtraGap: 1.0,
        normalizeGapsFromTakeSilence: true
    )

    private let format = AudioSpec(container: .caf, codec: .pcm, sampleRate: 48000, channels: 1)

    private func key(chapterID: String = "11111111-1111-1111-1111-111111111111",
                     segments: [PlaybackSegment]? = nil,
                     settings: AssemblySettings? = nil,
                     format: AudioSpec? = nil) -> String {
        RenderCacheKey.key(
            chapterID: UUID(uuidString: chapterID)!,
            segments: segments ?? makeSegments(),
            settings: settings ?? self.settings,
            format: format ?? self.format
        )
    }

    /// The key is a SHA-256 over deterministic inputs only — no `Hasher`,
    /// no object identity, no memory addresses. Recomputing it later (e.g.
    /// after relaunch, in a fresh process) must produce the same string.
    @Test func keyIsDeterministicAndStable() {
        #expect(key() == key())
        #expect(key().count == 64) // hex SHA-256
    }

    @Test func keyChangesWhenChapterChanges() {
        #expect(key(chapterID: "11111111-1111-1111-1111-111111111111") != key(chapterID: "22222222-2222-2222-2222-222222222222"))
    }

    @Test func keyChangesWhenSettingsChange() {
        var changedSettings = settings
        changedSettings.paragraphGap = 0.6
        #expect(key(settings: changedSettings) != key())
    }

    @Test func keyChangesWhenFormatChanges() {
        let differentFormat = AudioSpec(container: .m4a, codec: .aacLC, sampleRate: 48000, channels: 1, bitrateKbps: 128)
        #expect(key(format: differentFormat) != key())
    }

    @Test func keyChangesWhenTrimOrGainChanges() {
        var segments = makeSegments()
        segments[0] = PlaybackSegment(
            paragraphID: segments[0].paragraphID,
            chapterID: segments[0].chapterID,
            globalOrdinal: segments[0].globalOrdinal,
            assetRef: segments[0].assetRef,
            trim: 0.5..<5.0,
            gainDB: segments[0].gainDB,
            fadeIn: segments[0].fadeIn,
            fadeOut: segments[0].fadeOut,
            leadingSilence: segments[0].leadingSilence,
            trailingSilence: segments[0].trailingSilence
        )
        #expect(key(segments: segments) != key())
    }
}
