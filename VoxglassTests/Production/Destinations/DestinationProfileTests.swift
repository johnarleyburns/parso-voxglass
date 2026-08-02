import Foundation
import Testing
import VoxglassCore

/// The executable copy of §3's research dossier: if a platform changes its
/// rules, this test fails and the `// verified` dates in `DestinationTypes.swift`
/// must be revisited (§21.3).
@Suite struct DestinationProfileTests {

    @Test func librivoxProfileMatchesSpec() {
        let p = DestinationProfile.librivox
        #expect(p.id == .librivox)
        #expect(p.tier == .free)
        #expect(p.audio.container == .mp3)
        #expect(p.audio.codec == .mp3)
        #expect(p.audio.sampleRate == 44_100)
        #expect(p.audio.channels == 1)
        #expect(p.audio.bitrateKbps == 128)
        #expect(p.audio.isCBR == true)
        #expect(p.fileGranularity == .perChapter)
        #expect(p.maxFileDuration == nil)
        #expect(p.filenameRule == .librivoxLowercaseNoSpace)
        #expect(p.requiresHumanNarration == true)
        #expect(p.requiresScriptedDisclaimer == true)
        #expect(p.loudness == .replayGainBand(low: 86, high: 92, target: 89))
        #expect(p.peakCeilingDBFS == -0.3)
        #expect(p.noiseFloorCeilingDBFS == nil)
        #expect(p.artwork == .optionalSquare(minPx: 1000))
        #expect(p.emitsChecksums == true)
        #expect(p.autoUpload == false)
    }

    @Test func internetArchiveProfileMatchesSpec() {
        let p = DestinationProfile.internetArchive
        #expect(p.id == .internetArchive)
        #expect(p.tier == .free)
        #expect(p.audio.container == .flac)
        #expect(p.audio.codec == .flac)
        #expect(p.audio.sampleRate == nil)
        #expect(p.secondaryAudio?.container == .mp3)
        #expect(p.secondaryAudio?.bitrateKbps == 192)
        #expect(p.secondaryAudio?.isCBR == true)
        #expect(p.fileGranularity == .perChapter)
        #expect(p.filenameRule == .archiveIdentifierPrefixed)
        #expect(p.requiresHumanNarration == false)
        #expect(p.peakCeilingDBFS == -0.1)
        #expect(p.artwork == .optionalSquare(minPx: 1000))
        #expect(p.autoUpload == false)
    }

    @Test func acxProfileMatchesSpec() {
        let p = DestinationProfile.acx
        #expect(p.id == .acx)
        #expect(p.tier == .pro)
        #expect(p.audio.container == .mp3)
        #expect(p.audio.codec == .mp3)
        #expect(p.audio.sampleRate == 44_100)
        #expect(p.audio.channels == 1)
        #expect(p.audio.bitrateKbps == 192)
        #expect(p.audio.isCBR == true)
        #expect(p.fileGranularity == .perChapter)
        #expect(p.maxFileDuration == TimeInterval(120 * 60))
        #expect(p.filenameRule == .freeformNumbered)
        #expect(p.requiresCredits == true)
        #expect(p.loudness == .rmsWindow(minDBFS: -23, maxDBFS: -18, targetDBFS: -20))
        #expect(p.peakCeilingDBFS == -3.0)
        #expect(p.noiseFloorCeilingDBFS == -60.0)
        #expect(p.headroomSilence == SilenceRule(headMin: 0.5, headMax: 1.0, tailMin: 1.0, tailMax: 5.0))
        #expect(p.retailSample == RetailSampleRule(minDuration: 60, maxDuration: 300, mustStartWithNarration: true))
        #expect(p.artwork == .requiredSquare(minPx: 2400, colorSpace: .rgb, format: .jpeg))
        #expect(p.autoUpload == false)
    }

    @Test func appleBooksAggregatorProfileMatchesSpec() {
        let p = DestinationProfile.appleBooksAggregator
        #expect(p.id == .appleBooksAggregator)
        #expect(p.tier == .pro)
        #expect(p.audio.container == .m4b)
        #expect(p.audio.codec == .aacLC)
        #expect(p.audio.bitrateKbps == 128)
        #expect(p.fileGranularity == .wholeBookChapterized)
        #expect(p.requiresCredits == true)
        #expect(p.retailSample?.minDuration == 60)
        #expect(p.retailSample?.maxDuration == 300)
    }

    @Test func losslessMasterProfileMatchesSpec() {
        let p = DestinationProfile.losslessMaster
        #expect(p.id == .personalMaster)
        #expect(p.tier == .free)
        #expect(p.audio.container == .wav)
        #expect(p.audio.codec == .pcm)
        #expect(p.fileGranularity == .perChapter)
        #expect(p.requiredMetadata == [.title])
        #expect(p.artwork == .none)
        #expect(p.autoUpload == false)
    }

    @Test func profileRegistryResolvesEveryID() {
        for id in DestinationID.allCases {
            let profile = DestinationProfile.profile(for: id)
            #expect(profile.id == id)
        }
    }

    @Test func requiredMetadataSetsMatchSpec() {
        #expect(DestinationProfile.librivox.requiredMetadata.contains(.sourceURL))
        #expect(DestinationProfile.librivox.requiredMetadata.contains(.rightsAttestation))
        #expect(DestinationProfile.internetArchive.requiredMetadata.contains(.identifier))
        #expect(DestinationProfile.internetArchive.requiredMetadata.contains(.licenseURL))
        #expect(DestinationProfile.acx.requiredMetadata.contains(.copyrightYear))
        #expect(DestinationProfile.acx.requiredMetadata.contains(.rightsBasis))
    }

    @Test func autoUploadIsAlwaysFalse() {
        for id in DestinationID.allCases {
            #expect(DestinationProfile.profile(for: id).autoUpload == false, "autoUpload must always be false (C-7)")
        }
    }

    @Test func monoIsExpectedAcrossSpeechDestinations() {
        for id in [DestinationID.librivox, .acx, .appleBooksAggregator] {
            #expect(DestinationProfile.profile(for: id).audio.channels == 1)
        }
    }
}
