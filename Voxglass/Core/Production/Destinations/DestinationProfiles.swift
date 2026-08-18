import Foundation

// MARK: - Standard destination profiles
//
// The literal platform numbers in this file are the executable copy of the
// §3 research tables. Each constant carries a `// verified <date>` citation
// (§21.3); re-verification updates `DESTINATION_VERIFICATION_LOG.md` and this
// comment, never the numbers themselves.
//
// The `DestinationProfile` *type* stays in `Domain/DestinationTypes.swift`;
// only the literals and the registry live here (§4.1).

extension DestinationProfile {
    public static func destination(for purpose: ProjectPurpose) -> DestinationID {
        switch purpose {
        case .personal: return .personalMaster
        case .commercial: return .acx
        case .publicDomainCommunity: return .librivox
        }
    }

    public static func requiresRightsAttestation(_ destination: DestinationID) -> Bool {
        destination != .personalMaster
    }

    /// Personal Voxglass Listening — free local AAC/M4A playback copy.
    public static let personalListeningAudio = AudioSpec(
        container: .m4a, codec: .aacLC, sampleRate: 44_100, channels: 1, bitrateKbps: 128
    )

    /// LibriVox Contribution — mono MP3, 44.1 kHz, 128 kbps CBR.
    // verified 2026-08-02: LibriVox tech specs (128 kbps CBR MP3, 44.1 kHz mono); human-narration and disclaimer required
    public static let librivox = DestinationProfile(
        id: .librivox,
        displayName: "LibriVox Contribution",
        tier: .free,
        audio: AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 128, isCBR: true),
        fileGranularity: .perChapter,
        maxFileDuration: nil,
        filenameRule: .librivoxLowercaseNoSpace,
        requiredMetadata: [.title, .author, .narrator, .language, .sourceURL, .rightsBasis, .rightsAttestation],
        requiresHumanNarration: true,
        requiresScriptedDisclaimer: true,
        loudness: .replayGainBand(low: 86, high: 92, target: 89),
        peakCeilingDBFS: -0.3,
        noiseFloorCeilingDBFS: nil,
        artwork: .optionalSquare(minPx: 1000),
        emitsChecksums: true
    )

    /// Internet Archive — lossless FLAC primary, MP3 192 kbps CBR secondary.
    // verified 2026-08-02: IA audio upload guidance (FLAC or MP3 192 kbps CBR preferred; item derives from FLAC)
    public static let internetArchive = DestinationProfile(
        id: .internetArchive,
        displayName: "Internet Archive",
        tier: .free,
        audio: AudioSpec(container: .flac, codec: .flac),
        secondaryAudio: AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 192, isCBR: true),
        fileGranularity: .perChapter,
        maxFileDuration: nil,
        filenameRule: .archiveIdentifierPrefixed,
        requiredMetadata: [.title, .author, .narrator, .language, .date, .identifier, .licenseURL],
        requiresHumanNarration: false,
        requiresScriptedDisclaimer: false,
        peakCeilingDBFS: -0.1,
        artwork: .optionalSquare(minPx: 1000),
        emitsChecksums: true
    )

    /// ACX / Audible — mono MP3, 44.1 kHz, 192 kbps CBR, -20 dBFS RMS window.
    // verified 2026-08-02: ACX audio submission requirements (192 kbps CBR, 44.1 kHz, -23..-18 dBFS, -60 dB noise floor, 2400 px square cover)
    public static let acx = DestinationProfile(
        id: .acx,
        displayName: "ACX / Audible",
        tier: .pro,
        audio: AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 192, isCBR: true),
        fileGranularity: .perChapter,
        maxFileDuration: 120 * 60,
        filenameRule: .freeformNumbered,
        requiredMetadata: [.title, .author, .narrator, .language, .cover, .copyrightYear, .rightsBasis, .rightsAttestation],
        requiresHumanNarration: false,
        requiresScriptedDisclaimer: false,
        requiresCredits: true,
        loudness: .rmsWindow(minDBFS: -23, maxDBFS: -18, targetDBFS: -20),
        peakCeilingDBFS: -3.0,
        noiseFloorCeilingDBFS: -60.0,
        headroomSilence: SilenceRule(headMin: 0.5, headMax: 1.0, tailMin: 1.0, tailMax: 5.0),
        retailSample: RetailSampleRule(minDuration: 60, maxDuration: 300, mustStartWithNarration: true),
        artwork: .requiredSquare(minPx: 2400, colorSpace: .rgb, format: .jpeg),
        emitsChecksums: true
    )

    /// Apple Books / Aggregator — M4B AAC primary, MP3 192 kbps CBR secondary.
    // verified 2026-08-02: Apple Books audiobook intake guidance (M4B chapterized, AAC, square cover 2400 px, -20 dBFS RMS window)
    public static let appleBooksAggregator = DestinationProfile(
        id: .appleBooksAggregator,
        displayName: "Apple Books / Aggregator",
        tier: .pro,
        audio: AudioSpec(container: .m4b, codec: .aacLC, sampleRate: 44_100, channels: 1, bitrateKbps: 128),
        secondaryAudio: AudioSpec(container: .mp3, codec: .mp3, sampleRate: 44_100, channels: 1, bitrateKbps: 192, isCBR: true),
        fileGranularity: .wholeBookChapterized,
        maxFileDuration: nil,
        filenameRule: .freeformNumbered,
        requiredMetadata: [.title, .author, .narrator, .language, .cover, .publisher, .copyrightYear, .description],
        requiresHumanNarration: false,
        requiresScriptedDisclaimer: false,
        requiresCredits: true,
        loudness: .rmsWindow(minDBFS: -23, maxDBFS: -18, targetDBFS: -20),
        peakCeilingDBFS: -3.0,
        noiseFloorCeilingDBFS: -60.0,
        headroomSilence: SilenceRule(headMin: 0.5, headMax: 1.0, tailMin: 1.0, tailMax: 5.0),
        retailSample: RetailSampleRule(minDuration: 60, maxDuration: 300, mustStartWithNarration: true),
        artwork: .requiredSquare(minPx: 2400, colorSpace: .rgb, format: .jpeg),
        emitsChecksums: true
    )

    /// Lossless Chapter Masters — WAV/PCM, no loudness or artwork rules.
    // verified 2026-08-02: internal lossless master profile (WAV/PCM; no external intake requirements)
    public static let losslessMaster = DestinationProfile(
        id: .personalMaster,
        displayName: "Lossless Chapter Masters",
        tier: .free,
        audio: AudioSpec(container: .wav, codec: .pcm),
        fileGranularity: .perChapter,
        maxFileDuration: nil,
        filenameRule: .freeformNumbered,
        requiredMetadata: [.title],
        requiresHumanNarration: false,
        requiresScriptedDisclaimer: false,
        peakCeilingDBFS: -0.1,
        artwork: .none,
        emitsChecksums: true
    )

    /// The single registry the app consults to map a `DestinationID` to its
    /// profile (validation screen, export wizard, packaging builders).
    public static func profile(for id: DestinationID) -> DestinationProfile {
        switch id {
        case .librivox: return .librivox
        case .internetArchive: return .internetArchive
        case .acx: return .acx
        case .appleBooksAggregator: return .appleBooksAggregator
        case .personalMaster: return .losslessMaster
        }
    }
}
